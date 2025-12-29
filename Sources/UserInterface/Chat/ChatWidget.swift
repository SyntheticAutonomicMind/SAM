// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import AppKit
import APIFramework
import ConversationEngine
import ConfigurationSystem
import MCPFramework
import SharedData
import VoiceFramework
import Logging
import Combine
import StableDiffusionIntegration

/// ChatWidget with dynamic model loading, performance tracking, copy functionality, and chat management Includes chat duplication, JSON export, and session persistence features.
public struct ChatWidget: View {
    @EnvironmentObject private var endpointManager: EndpointManager
    let activeConversation: ConversationModel?
    @ObservedObject private var messageBus: ConversationMessageBus
    @Binding var showingMiniPrompts: Bool
    private let logger = Logging.Logger(label: "com.sam.chat")
    @EnvironmentObject private var conversationManager: ConversationManager
    @EnvironmentObject private var sharedConversationService: SharedConversationService

    @State private var messageText = ""

    /// Track previous conversation for draft save/restore
    @State private var previousConversationId: UUID?

    /// Debounced draft save task - prevents excessive disk writes while typing
    @State private var draftSaveTask: Task<Void, Never>?

    /// Messages directly from MessageBus (single source of truth)
    /// MessageBus is @ObservedObject - SwiftUI automatically re-renders on @Published changes
    /// This is the CORRECT data flow: MessageBus → ChatWidget (not MessageBus → ConversationModel → ChatWidget)
    private var messages: [EnhancedMessage] {
        messageBus.messages
    }

    @State private var cachedToolHierarchy: [UUID: [EnhancedMessage]] = [:]

    /// PERFORMANCE: Cache cleaned messages to avoid regex operations on every render
    /// Key: message.id, Value: (contentHash, cleanedMessage)
    /// Only recompute cleanSpecialTokens when content actually changes
    @State private var cachedCleanedMessages: [UUID: (contentHash: Int, cleaned: EnhancedMessage)] = [:]

    @State private var processingStatus: ProcessingStatus = .idle
    @State private var currentToolName: String?
    @State private var isSending = false
    @State private var streamingTask: Task<Void, Never>?

    /// Current orchestrator for cancellation support
    @State private var currentOrchestrator: AgentOrchestrator?

    /// Input focus state for auto-focus on chat open.
    @FocusState private var isInputFocused: Bool

    /// PERFORMANCE: Streaming update throttling.
    @State private var pendingStreamingUpdate: (messageId: UUID, content: String)?
    @State private var streamingUpdateTask: Task<Void, Never>?
    @State private var lastUIUpdateTime: Date = Date()
    @State private var streamingUpdateCount: Int = 0

    /// PERFORMANCE: Scroll throttling for large conversations
    /// Single consolidated scroll system to prevent bounce from competing scroll calls
    @State private var lastScrollTime: Date = .distantPast
    @State private var pendingScrollTask: Task<Void, Never>?
    @State private var isScrolling: Bool = false
    @State private var lastScrolledToId: UUID?

    /// Scroll proxy for keyboard navigation (stored from ScrollViewReader)
    @State private var scrollProxy: ScrollViewProxy?

    /// Auto-scroll control: user explicitly enables/disables via toggle.
    /// Global and persistent across all conversations and app restarts.
    @AppStorage("scrollLockEnabled") private var scrollLockEnabled: Bool = true

    /// User collaboration state.
    @State private var isAwaitingUserInput = false
    @State private var userCollaborationPrompt = ""
    @State private var userCollaborationContext: String?
    @State private var userCollaborationToolCallId: String?

    /// CRITICAL: Prevents conversation sync from overwriting streaming messages
    /// During active streaming, UI is source of truth - DO NOT load from conversation
    @State private var isActivelyStreaming = false

    /// Thinking indicator for UI feedback.
    @State private var isThinking = false
    /// DEPRECATED: showThinkingSteps moved to per-conversation enableReasoning toggle.
    @State private var lastToolProcessorMessage = false
    @State private var lastToolName: String?
    @State private var lastToolExecutionId: String?

    /// Appearance preferences.
    @AppStorage("enableAnimations") private var enableAnimations: Bool = true

    /// Flag to prevent syncSettingsToConversation during syncWithActiveConversation.
    @State private var isLoadingConversationSettings = false

    /// Flag to prevent bidirectional sync loop between UI and ConversationModel.
    @State private var isSyncingMessages = false

    /// Combine subscription to observe conversation changes.
    @State private var conversationSubscription: AnyCancellable?

    /// FEATURE: Enable/disable tool usage.
    @State private var enableTools: Bool = true

    /// FEATURE: Auto-approve tool execution (bypasses security).
    @State private var autoApprove: Bool = false
    @State private var showAutoApproveWarning: Bool = false
    @State private var dontShowAutoApproveAgain: Bool = false
    @AppStorage("hasSeenAutoApproveWarning") private var hasSeenAutoApproveWarning: Bool = false

    /// SECURITY: Terminal access control (disabled by default).
    @State private var enableTerminalAccess: Bool = false
    @State private var terminalStateBeforeDisable: Bool = false

    /// Workflow mode control (disabled by default).
    @State private var enableWorkflowMode: Bool = false

    /// Dynamic iterations control (disabled by default).
    @State private var enableDynamicIterations: Bool = false

    /// FEATURE: Direct Stable Diffusion mode (when SD model selected with no LLM).
    @State private var isStableDiffusionOnlyMode: Bool = false

    /// Stable Diffusion default settings.
    @AppStorage("sd_default_steps") private var sdDefaultSteps: Int = 25
    @AppStorage("sd_default_guidance") private var sdDefaultGuidance: Int = 8
    @AppStorage("sd_default_scheduler") private var sdDefaultScheduler: String = "dpm++"
    @AppStorage("sd_default_negative_prompt") private var sdDefaultNegativePrompt: String = ""
    @AppStorage("sd_remember_settings") private var sdRememberSettings: Bool = false

    /// Stable Diffusion UI state variables (synced with conversation.settings)
    @State private var sdSteps: Int = 25
    @State private var sdGuidanceScale: Int = 8
    @State private var sdScheduler: String = "dpm++"
    @State private var sdNegativePrompt: String = ""
    @State private var sdSeed: Int = -1
    @State private var sdUseKarras: Bool = true
    @State private var sdImageCount: Int = 1
    @State private var sdImageWidth: Int = 512
    @State private var sdImageHeight: Int = 512
    @State private var sdEngine: String = "coreml"  /// "coreml" or "python"
    @State private var sdDevice: String = "auto"  /// "auto", "mps", "cpu" (Python engine only)
    @State private var sdUpscaleModel: String = "none"  /// "none", "general", "anime", "general_x2"
    @State private var sdStrength: Double = 0.75  /// Denoising strength for img2img (0.0-1.0)
    @State private var sdInputImagePath: String?  /// Input image path for img2img

    /// Shared data UI state
    @State private var useSharedData: Bool = false
    @State private var assignedSharedTopicId: String?
    @State private var sharedTopics: [SharedTopic] = []
    private let sharedTopicManager = SharedTopicManager()

    /// Configuration - dynamically loaded.
    @AppStorage("defaultModel") private var appDefaultModel: String = "gpt-4"
    @State private var selectedModel: String = "gpt-4"
    @State private var temperature: Double = 0.7
    @State private var topP: Double = 1.0
    @State private var repetitionPenalty: Double?
    @State private var maxTokens: Int? = 8192
    @State private var maxMaxTokens: Int = 16384
    @State private var contextWindowSize: Int = 4096
    @State private var maxContextWindowSize: Int = 32768
    @State private var availableModels: [String] = []
    @State private var loadingModels = false
    @State private var enableReasoning: Bool = false

    /// Current model cost display (updated when model changes)
    @State private var currentModelCost: String = "0x"

    /// Local model loading state.
    @State private var isLocalModelLoaded: Bool = false
    @State private var isLoadingLocalModel: Bool = false

    /// Track if user manually overrode auto-disable tools for local models.
    @State private var userManuallyEnabledTools: Bool = false

    /// Memory validation state.
    private let localModelManager = LocalModelManager()
    @State private var showMemoryWarning: Bool = false
    @State private var memoryWarningMessage: String = ""
    @State private var pendingModelLoad: (provider: String, model: String)?

    /// Advanced parameters toolbar - collapsible.
    @State private var showAdvancedParameters = false

    /// System prompt management - using systemPromptManager.selectedConfigurationId as single source of truth.
    @ObservedObject private var systemPromptManager = SystemPromptManager.shared

    /// Chat session management.
    @StateObject private var chatManager = ChatManager()
    @State private var showingExportOptions = false

    /// Message export - centralized at ChatWidget level for reliable sheet presentation.
    @State private var messageToExport: EnhancedMessage?

    /// Performance monitoring.
    @StateObject private var performanceMonitor = PerformanceMonitor()
    @State private var showingPerformanceMetrics = false

    /// Voice input/output management.
    @ObservedObject private var voiceManager = VoiceManager.shared
    @StateObject private var voiceBridge = VoiceChatBridge()
    @State private var showVoiceAuthError = false
    @State private var voiceAuthErrorMessage = ""
    
    /// API error notification
    @State private var showAPIError = false
    @State private var apiErrorMessage = ""
    
    /// Rate limit notification
    @State private var showRateLimitAlert = false
    @State private var rateLimitMessage = ""
    @State private var rateLimitRetrySeconds: Double = 0

    /// Stable Diffusion model management.
    @StateObject private var sdModelManager = StableDiffusionModelManager()

    /// Document import system for auto-importing attached files
    @State private var documentImportSystem: DocumentImportSystem?

    /// Todo list manager (shared singleton)
    @ObservedObject private var todoManager = TodoManager.shared

    /// Memory management - Session Intelligence.
    @State private var showingMemoryPanel = false
    @State private var memoryStatistics: ConversationEngine.MemoryStatistics?
    @State private var archiveStatistics: MemoryMap?
    @State private var contextStatistics: ContextStatistics?
    @State private var conversationMemories: [ConversationMemory] = []
    @State private var memorySearchQuery = ""
    @State private var searchInStored = true
    @State private var searchInActive = false
    @State private var searchInArchive = false

    /// Terminal panel.
    @State private var showingTerminalPanel = false

    /// Working directory panel.
    @State private var showingWorkingDirectoryPanel = false

    /// File attachments for current conversation.
    /// Files are copied to working directory and their paths stored here for context injection.
    @State private var attachedFiles: [URL] = []

    /// Flag to prevent sending while files are being copied
    @State private var isAttachingFiles: Bool = false

    /// Agent todo list.
    @State private var showingTodoListPopover = false
    /// Agent todo list - computed from TodoManager (reactive to changes)
    private var agentTodoList: [AgentTodoItem] {
        guard let conversationId = activeConversation?.id.uuidString else {
            return []
        }

        let todoList = todoManager.readTodoList(for: conversationId)
        return todoList.items.map { item in
            AgentTodoItem(
                id: item.id,
                title: item.title,
                description: item.description,
                status: item.status.rawValue
            )
        }
    }

    /// Terminal managers now stored in ConversationManager for persistence across view recreations Previously stored as @State which caused terminal history loss when switching conversations.

    public init(activeConversation: ConversationModel? = nil, messageBus: ConversationMessageBus, showingMiniPrompts: Binding<Bool>) {
        self.activeConversation = activeConversation
        self.messageBus = messageBus
        self._showingMiniPrompts = showingMiniPrompts
    }

    /// Check if input should be disabled (when model needs loading)
    private var shouldDisableInput: Bool {
        return endpointManager.isLocalModel(selectedModel) && !isLocalModelLoaded
    }

    public var body: some View {
        Group {
            mainChatView
        }
            .alert("Enable Auto-Approve Mode?", isPresented: $showAutoApproveWarning) {
                Button("Cancel", role: .cancel) {
                    /// User declined - revert toggle and optionally suppress future warnings.
                    autoApprove = false
                    if dontShowAutoApproveAgain {
                        hasSeenAutoApproveWarning = true
                    }
                    dontShowAutoApproveAgain = false
                }
                Button("Enable", role: .destructive) {
                    /// User confirmed - enable auto-approve.
                    /// CRITICAL: Set flag BEFORE changing autoApprove to prevent onChange from re-triggering warning.
                    hasSeenAutoApproveWarning = true
                    dontShowAutoApproveAgain = false
                    autoApprove = true
                    /// Sync and update AuthorizationManager.
                    syncSettingsToConversation()
                    if let conversationId = activeConversation?.id {
                        AuthorizationManager.shared.setAutoApprove(true, conversationId: conversationId)
                    }
                }
                Toggle("Don't show this warning again", isOn: $dontShowAutoApproveAgain)
            } message: {
                Text("""
                    **WARNING** Security Feature Bypass **WARNING**

                    Auto-approve mode allows the AI agent to execute ANY tool operation without asking for your permission first.

                    This includes:
                    • File creation, modification, and deletion
                    • Terminal command execution
                    • Web research and data retrieval
                    • Document creation and imports

                    It will have full authority to execute any of these actions without your explicit consent which could be destructive to your data or your system. Only enable this if you fully trust the AI agent and understand the risks.

                    You can disable this at any time using the toggle in the chat controls.
                    """)
            }
            .alert("Memory Warning", isPresented: $showMemoryWarning) {
                Button("Cancel", role: .cancel) {
                    pendingModelLoad = nil
                }
                Button("Load Anyway", role: .destructive) {
                    if let pending = pendingModelLoad {
                        logger.warning("CHATWIDGET: User overrode memory warning for \(pending.provider)/\(pending.model)")
                        performModelLoad()
                    }
                    pendingModelLoad = nil
                }
            } message: {
                Text(memoryWarningMessage)
            }
            .sheet(item: $messageToExport) { message in
                if let activeConv = activeConversation {
                    ExportDialog(conversation: activeConv, message: message, isPresented: Binding(
                        get: { messageToExport != nil },
                        set: { if !$0 { messageToExport = nil } }
                    ))
                }
            }
            .alert("Speech Recognition Not Enabled", isPresented: $showVoiceAuthError) {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Siri")!)
                }
                Button("OK", role: .cancel) { }
            } message: {
                Text(voiceAuthErrorMessage)
            }
            .alert("API Error", isPresented: $showAPIError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(apiErrorMessage)
            }
            .alert("Rate Limited", isPresented: $showRateLimitAlert) {
                Button("OK", role: .cancel) {
                    showRateLimitAlert = false
                }
            } message: {
                Text(rateLimitMessage)
            }
            .onChange(of: showingMemoryPanel) { _, newValue in
                savePanelState(panel: "memory", value: newValue)
                if newValue { loadMemoryStatistics() }
            }
            .onChange(of: showingTerminalPanel) { _, newValue in
                savePanelState(panel: "terminal", value: newValue)
            }
            .onChange(of: showingWorkingDirectoryPanel) { _, newValue in
                savePanelState(panel: "workdir", value: newValue)
            }
            .onChange(of: showAdvancedParameters) { _, newValue in
                savePanelState(panel: "advanced", value: newValue)
            }
            .onChange(of: showingPerformanceMetrics) { _, newValue in
                savePanelState(panel: "perf", value: newValue)
            }
    }

    /// Scroll lock is now in toolbar (removed overlay)

    /// Conditional panels shown above input area
    @ViewBuilder
    private var conditionalPanels: some View {
        if showingPerformanceMetrics {
            Divider()
            UserInterface.PerformanceMetricsView(
                performanceMonitor: performanceMonitor,
                isVisible: $showingPerformanceMetrics
            )
        }

        if showingMemoryPanel {
            Divider()
            sessionIntelligencePanel
        }

        if showingWorkingDirectoryPanel {
            Divider()
            workingDirectoryPanel
        }

        if showingTerminalPanel {
            Divider()
            TerminalView(
                terminalManager: getTerminalManager(),
                isVisible: $showingTerminalPanel
            )
        }
    }

    /// Main content layout without modifiers
    private var mainChatContent: some View {
        VStack(spacing: 0) {
            chatHeader
            Divider()
            messageList
            conditionalPanels
            Divider()
            messageInput
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var mainChatView: some View {
        mainChatContent
            .sheet(isPresented: $showingExportOptions) {
                exportChatDialog
            }
            .onAppear {
            SAMLog.chatViewAppear()
            loadAvailableModels()
            loadSystemPrompts()
            loadRecentChatSession()
            syncWithActiveConversation()

            /// Detect SD-only mode on load (Bug #1 fix) - includes local sd/ and remote alice- models
            if let activeConv = conversationManager.activeConversation {
                let isSDModel = activeConv.settings.selectedModel.hasPrefix("sd/") || activeConv.settings.selectedModel.hasPrefix("alice-")
                isStableDiffusionOnlyMode = isSDModel
                if isSDModel {
                    logger.info("Detected SD-only mode on load: \(activeConv.settings.selectedModel)")
                }
            }

            /// Check if local model is already loaded on startup (Issue #1: input box disabled)
            Task {
                await loadSharedTopics()

                /// Check model loading status for current model
                if endpointManager.isLocalModel(selectedModel) {
                    let loaded = await endpointManager.getModelLoadingStatus(selectedModel)
                    await MainActor.run {
                        isLocalModelLoaded = loaded
                        logger.info("STARTUP: Local model \(selectedModel) loaded status: \(loaded)")
                    }
                }

                /// Update model max tokens/context from configuration (Issue #2: parameters not set)
                updateMaxContextForModel()
            }

            // If this ChatWidget is for a new conversation (no activeConversation),
            // initialize selectedModel from the global default set in preferences.
            if activeConversation == nil {
                selectedModel = appDefaultModel
            }

            /// Initialize cost display for current model on first load
            currentModelCost = getCostDisplay(for: selectedModel)
            logger.info("CHATWIDGET INIT: selectedModel=\(selectedModel), cost=\(currentModelCost)")

            /// Setup voice manager callbacks via bridge
            setupVoiceCallbacks()

            /// Listen for model updates from file system changes.
            NotificationCenter.default.addObserver(
                forName: .endpointManagerDidUpdateModels,
                object: nil,
                queue: .main
            ) { _ in
                Task {
                    await loadAvailableModels()
                }
            }

            /// Listen for Stable Diffusion model installations
            NotificationCenter.default.addObserver(
                forName: .stableDiffusionModelInstalled,
                object: nil,
                queue: .main
            ) { _ in
                Task {
                    await loadAvailableModels()
                }
            }

            /// Listen for ALICE remote models becoming available
            NotificationCenter.default.addObserver(
                forName: .aliceModelsLoaded,
                object: nil,
                queue: .main
            ) { _ in
                logger.info("ALICE models loaded, refreshing available models list")
                Task {
                    await loadAvailableModels()
                }
            }
            
            /// Listen for rate limit notifications
            NotificationCenter.default.addObserver(
                forName: .providerRateLimitHit,
                object: nil,
                queue: .main
            ) { notification in
                guard let userInfo = notification.userInfo,
                      let retrySeconds = userInfo["retryAfterSeconds"] as? Double,
                      let providerName = userInfo["providerName"] as? String else {
                    return
                }
                
                rateLimitRetrySeconds = retrySeconds
                rateLimitMessage = "\(providerName) rate limit reached. Retrying in \(Int(retrySeconds)) seconds..."
                showRateLimitAlert = true
            }
            
            /// Listen for rate limit retry
            NotificationCenter.default.addObserver(
                forName: .providerRateLimitRetrying,
                object: nil,
                queue: .main
            ) { _ in
                showRateLimitAlert = false
            }

            /// Auto-focus input box when chat opens.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isInputFocused = true
            }
        }
        .onChange(of: activeConversation?.id) { _, newID in
            /// FEATURE: Save draft message from previous conversation before switching
            if let prevId = previousConversationId,
               let prevConversation = conversationManager.conversations.first(where: { $0.id == prevId }) {
                if !messageText.isEmpty {
                    prevConversation.settings.draftMessage = messageText
                    /// Save immediately when switching (no debounce)
                    conversationManager.saveConversations()
                    logger.debug("DRAFT_SAVE: Saved draft (\(messageText.count) chars) to conversation \(prevId.uuidString.prefix(8))")
                }
            }

            /// Cancel any pending debounced draft save
            draftSaveTask?.cancel()
            draftSaveTask = nil

            /// Update previous conversation ID tracking
            previousConversationId = newID

            /// Log conversation opening with full message details
            if let conv = activeConversation {
                logger.debug("[CONVERSATION_OPENED] id=\(conv.id.uuidString.prefix(8)), title='\(conv.title)', messageCount=\(conv.messages.count)")
                for (index, msg) in conv.messages.enumerated() {
                    logger.debug("[MSG_INDEX_\(index)] id=\(msg.id.uuidString.prefix(8)), from=\(msg.isFromUser ? "user" : "assistant"), len=\(msg.content.count), type=\(msg.type)")
                }

                /// FEATURE: Restore draft message from new conversation
                let draftMessage = conv.settings.draftMessage
                if !draftMessage.isEmpty {
                    messageText = draftMessage
                    logger.debug("DRAFT_RESTORE: Restored draft (\(draftMessage.count) chars) from conversation \(conv.id.uuidString.prefix(8))")
                } else {
                    /// Clear input when switching to conversation with no draft
                    messageText = ""
                }
            }

            /// Cancel active tasks when switching conversations.
            /// Prevents ghost tasks from continuing and updating the wrong conversation.
            streamingTask?.cancel()
            streamingTask = nil
            streamingUpdateTask?.cancel()
            streamingUpdateTask = nil

            /// Cancel local model generation if running.
            Task {
                await endpointManager.cancelLocalModelGeneration()
            }

            /// Restore UI state from StateManager (Task 18)
            /// This ensures UI correctly reflects state when switching back to a conversation where agent is working
            if let conversation = activeConversation {
                logger.debug("CONVERSATION_SWITCH: Switching to conversation \(conversation.id), checking StateManager...")

                /// Get runtime state from StateManager
                if let state = conversationManager.stateManager.getState(conversationId: conversation.id) {
                    logger.debug("CONVERSATION_SWITCH: Found state in StateManager: \(state.status)")

                    /// Restore processing status from state
                    switch state.status {
                    case .idle:
                        isSending = false
                        processingStatus = .idle
                        logger.debug("CONVERSATION_SWITCH: Restored idle state")
                    case .processing(let toolName):
                        isSending = true
                        /// Use tool-specific status if available
                        if let toolName = toolName {
                            processingStatus = .processingTools(toolName: toolName)
                            logger.debug("CONVERSATION_SWITCH: Restored processing state for tool: \(toolName)")
                        } else {
                            processingStatus = .generating
                            logger.debug("CONVERSATION_SWITCH: Restored generic processing state")
                        }
                    case .streaming:
                        isSending = true
                        processingStatus = .generating
                        logger.debug("CONVERSATION_SWITCH: Restored streaming state")
                    case .error(let msg):
                        isSending = false
                        processingStatus = .idle
                        logger.debug("CONVERSATION_SWITCH: Conversation has error state: \(msg)")
                    }
                } else {
                    logger.debug("CONVERSATION_SWITCH: No state in StateManager, using fallback")
                    /// No state in StateManager - use conversation.isProcessing as fallback
                    isSending = conversation.isProcessing
                    processingStatus = conversation.isProcessing ? .generating : .idle
                }
            } else {
                isSending = false
                processingStatus = .idle
            }

            /// Cancel previous subscription.
            conversationSubscription?.cancel()

            /// Set up new subscription to observe conversation changes.
            if let conversation = activeConversation {
                conversationSubscription = conversation.objectWillChange
                    .receive(on: DispatchQueue.main)
                    .sink { _ in
                        /// Only sync if not currently streaming.
                        guard processingStatus != .thinking && processingStatus != .generating else { return }

                        logger.debug("MESSAGE_LIFECYCLE: Conversation objectWillChange detected, syncing to UI")
                        syncWithActiveConversation()
                    }
            }

            syncWithActiveConversation()
        }
        .onAppear {
            /// Sync messages on initial view appearance.
            /// onChange(of: activeConversation?.id) doesn't fire if conversation is already set before view loads.
            logger.debug("MESSAGE_LIFECYCLE: ChatWidget appeared, triggering initial sync")
            syncWithActiveConversation()

            /// FEATURE: Restore draft message on initial appearance
            /// This handles the case where conversation is already set before view loads
            if let conversation = activeConversation {
                let draftMessage = conversation.settings.draftMessage
                if !draftMessage.isEmpty {
                    messageText = draftMessage
                    logger.debug("DRAFT_RESTORE: Restored draft on appear (\(draftMessage.count) chars) from conversation \(conversation.id.uuidString.prefix(8))")
                }
                /// Track this conversation as previous for future switches
                previousConversationId = conversation.id
            }
        }
        .onChange(of: processingStatus) { oldValue, newValue in
            /// Sync messages when processing completes
            /// Problem: If message count doesn't change (placeholder updated), onChange doesn't fire
            /// Solution: Explicitly sync when transitioning from thinking/generating to idle
            if (oldValue == .thinking || oldValue == .generating) && newValue == .idle {
                logger.debug("MESSAGE_LIFECYCLE: Processing completed, triggering sync")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    syncWithActiveConversation()
                }
            }
        }
        .onReceive(voiceBridge.$transcribedText) { newValue in
            /// Handle voice transcription updates
            guard !newValue.isEmpty else { return }
            logger.debug("Voice transcription received: '\\(newValue)'")
            messageText = newValue
            voiceBridge.transcribedText = ""
        }
        .onReceive(voiceBridge.$shouldSendMessage) { newValue in
            /// Handle voice send command
            guard newValue else { return }
            if !messageText.isEmpty && !isSending {
                sendMessage()
            }
            voiceBridge.shouldSendMessage = false
        }
        .onReceive(voiceBridge.$shouldClearMessage) { newValue in
            /// Handle voice clear/cancel command
            guard newValue else { return }
            messageText = ""
            voiceBridge.shouldClearMessage = false
        }
        .onChange(of: selectedModel) { _, newValue in
            /// Don't save settings or trigger preload if we're loading from conversation.
            guard !isLoadingConversationSettings else { return }

            /// Detect Stable Diffusion-only mode (SD model with no LLM) - includes ALICE remote models
            let isSDModel = newValue.hasPrefix("sd/") || newValue.hasPrefix("alice-")
            isStableDiffusionOnlyMode = isSDModel

            if isSDModel {
                /// Initialize SD parameters from defaults if not already set
                if let activeConv = conversationManager.activeConversation {
                    if activeConv.settings.sdNegativePrompt.isEmpty && activeConv.settings.sdSteps == 25 {
                        /// Looks like defaults, initialize from user preferences
                        activeConv.settings.sdNegativePrompt = sdDefaultNegativePrompt
                        activeConv.settings.sdSteps = sdDefaultSteps
                        activeConv.settings.sdGuidanceScale = sdDefaultGuidance
                        activeConv.settings.sdScheduler = sdDefaultScheduler
                    }
                }
                logger.info("Switched to Stable Diffusion-only mode: \(newValue)")

                /// Auto-adjust parameters based on model type (Z-Image vs SD)
                /// Apply defaults if guidance is out of range for this model type
                if isZImageModel && sdGuidanceScale > guidanceScaleRange.upperBound {
                    sdGuidanceScale = defaultGuidanceScale
                    logger.info("Auto-adjusted guidance scale for Z-Image model: \(sdGuidanceScale)")
                } else if !isZImageModel && sdGuidanceScale < guidanceScaleRange.lowerBound {
                    sdGuidanceScale = defaultGuidanceScale
                    logger.info("Auto-adjusted guidance scale for SD model: \(sdGuidanceScale)")
                }

                /// Z-Image models now work on MPS with bfloat16 (2x faster than CPU)
                /// No automatic device switching needed - Python script handles dtype selection
                if isZImageModel {
                    logger.info("Z-Image model selected - MPS with bfloat16 is now supported")
                }

                /// Auto-adjust steps for Z-Image models if needed
                if isZImageModel {
                    /// For Z-Image, use model-appropriate defaults
                    let recommendedSteps = defaultSteps  /// 8 for turbo, 50 for standard
                    if abs(sdSteps - recommendedSteps) > 20 {
                        sdSteps = recommendedSteps
                        logger.info("Auto-adjusted steps for Z-Image model: \(sdSteps)")
                    }
                }

                /// SDXL models: Switch to Euler scheduler if using problematic schedulers
                /// EDMDPMSolverMultistepScheduler produces garbage images on MPS
                /// DPM++ SDE variants cause IndexError on SDXL
                if isSDXLModel {
                    let problematicSchedulers = ["dpm++_sde", "dpm++_sde_karras"]
                    if problematicSchedulers.contains(sdScheduler) {
                        sdScheduler = "euler"
                        logger.info("Auto-switched scheduler to Euler for SDXL model (previous scheduler causes issues on MPS)")
                    }
                }

                /// Validate image size for the selected model
                /// If current size isn't available for this model, default to first size
                let currentSize = "\(sdImageWidth)×\(sdImageHeight)"
                if !availableImageSizes.contains(currentSize) {
                    /// Default to first available size
                    if let firstSize = availableImageSizes.first {
                        let components = firstSize.split(separator: "×")
                        if components.count == 2,
                           let width = Int(components[0]),
                           let height = Int(components[1]) {
                            sdImageWidth = width
                            sdImageHeight = height
                            logger.info("Image size \(currentSize) not available for \(newValue), defaulting to \(firstSize)")
                        }
                    }
                }
            }

            /// Auto-select SAM Minimal for local models, SAM Default for remote models
            /// Only auto-switch if currently using SAM Default (00000000-0000-0000-0000-000000000001)
            /// Don't switch if user explicitly selected a different prompt
            if let activeConv = conversationManager.activeConversation {
                let samDefaultId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
                let samMinimalId = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
                let currentPromptId = activeConv.settings.selectedSystemPromptId ?? samDefaultId

                /// Only auto-switch between SAM Default <-> SAM Minimal
                /// Don't touch if user explicitly chose a custom or workspace prompt
                if currentPromptId == samDefaultId || currentPromptId == samMinimalId {
                    let isLocalModel = newValue.lowercased().contains("gguf") ||
                                      newValue.lowercased().contains("mlx") ||
                                      newValue.lowercased().contains("local-llama")

                    var updatedConv = activeConv
                    let targetPromptId = isLocalModel ? samMinimalId : samDefaultId

                    /// Only update if actually changing
                    if currentPromptId != targetPromptId {
                        updatedConv.settings.selectedSystemPromptId = targetPromptId
                        logger.info("Auto-selected \(isLocalModel ? "SAM Minimal" : "SAM Default") for \(isLocalModel ? "local" : "remote") model: \(newValue)")

                        /// Update conversation and save
                        conversationManager.activeConversation = updatedConv
                        conversationManager.saveConversations()

                        /// CRITICAL: Also update systemPromptManager.selectedConfigurationId
                        /// This is what generateSystemPrompt() uses to determine prompt content
                        systemPromptManager.selectedConfigurationId = targetPromptId
                    }
                }
            }

            updateMaxContextForModel()
            preloadModel()

            /// Update cost display for quota header
            currentModelCost = getCostDisplay(for: newValue)

            /// Check loading status for local models.
            Task {
                if endpointManager.isLocalModel(newValue) {
                    let loaded = await endpointManager.getModelLoadingStatus(newValue)
                    await MainActor.run {
                        isLocalModelLoaded = loaded
                        /// FIXED: Tools now enabled for local models - they support Hermes-style tool calling via system prompt injection
                    }
                } else {
                    /// Remote models are always "loaded"
                    await MainActor.run {
                        isLocalModelLoaded = false
                        userManuallyEnabledTools = false
                    }
                }
            }
        }
        .onChange(of: endpointManager.modelLoadingStatus) { _, newStatus in
            /// Update button states when model loading status changes (fixes play/eject button not updating when model loads during conversation start)
            guard endpointManager.isLocalModel(selectedModel) else { return }

            if let status = newStatus[selectedModel] {
                switch status {
                case .loading:
                    isLoadingLocalModel = true
                    isLocalModelLoaded = false
                case .loaded:
                    isLoadingLocalModel = false
                    isLocalModelLoaded = true
                case .notLoaded:
                    isLoadingLocalModel = false
                    isLocalModelLoaded = false
                }
                logger.debug("BUTTON_STATE_UPDATE: Model \(selectedModel) status changed to \(status), isLoadingLocalModel=\(isLoadingLocalModel), isLocalModelLoaded=\(isLocalModelLoaded)")
            }
        }
        .onChange(of: temperature) { _, _ in
            guard !isLoadingConversationSettings else { return }
            syncSettingsToConversation()
        }
        .onChange(of: topP) { _, _ in
            guard !isLoadingConversationSettings else { return }
            syncSettingsToConversation()
        }
        .onChange(of: enableReasoning) { _, _ in
            guard !isLoadingConversationSettings else { return }
            syncSettingsToConversation()
        }
        .onChange(of: enableTools) { oldValue, newValue in
            guard !isLoadingConversationSettings else { return }

            /// Track if user manually enabled tools for a local model This prevents auto-disable from overriding user choice.
            if endpointManager.isLocalModel(selectedModel) && newValue && !oldValue {
                userManuallyEnabledTools = true
                logger.info("CHATWIDGET: User manually enabled tools for local model: \(selectedModel)")
            } else if !newValue {
                /// Reset flag when user disables tools.
                userManuallyEnabledTools = false
            }

            syncSettingsToConversation()
        }
        .onChange(of: autoApprove) { _, newValue in
            guard !isLoadingConversationSettings else { return }

            /// Show warning dialog on first-time enable.
            if newValue && !hasSeenAutoApproveWarning {
                showAutoApproveWarning = true
                /// Revert toggle immediately (will be re-enabled if user confirms).
                autoApprove = false
                return
            }

            syncSettingsToConversation()
            /// Update AuthorizationManager.
            if let conversationId = activeConversation?.id {
                AuthorizationManager.shared.setAutoApprove(newValue, conversationId: conversationId)
            }
        }
        .onChange(of: maxTokens) { _, _ in
            guard !isLoadingConversationSettings else { return }
            syncSettingsToConversation()
        }
        .onChange(of: contextWindowSize) { _, _ in
            guard !isLoadingConversationSettings else { return }
            syncSettingsToConversation()
        }
        .onChange(of: systemPromptManager.selectedConfigurationId) { _, _ in
            guard !isLoadingConversationSettings else { return }
            syncSettingsToConversation()
        }
    }

    // MARK: - UI Setup

    private var sessionIntelligencePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Session Intelligence")
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                /// Close button.
                Button(action: {
                    withAnimation { showingMemoryPanel.toggle() }
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Session Intelligence panel")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            /// SECTION 1: Memory Status
            memoryStatusSection
                .padding(.horizontal, 16)

            Divider()
                .padding(.horizontal, 16)

            /// SECTION 2: Context Management
            contextManagementSection
                .padding(.horizontal, 16)

            Divider()
                .padding(.horizontal, 16)

            /// SECTION 3: Enhanced Search
            enhancedSearchSection
                .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .onAppear {
            loadMemoryStatistics()
        }
        .onChange(of: activeConversation?.id) { _, _ in
            loadMemoryStatistics()
            conversationMemories.removeAll()
            memorySearchQuery = ""
        }
        .onChange(of: activeConversation?.settings.sharedTopicId) { _, _ in
            loadMemoryStatistics()
            conversationMemories.removeAll()
            memorySearchQuery = ""
        }
    }

    private var memoryStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MEMORY STATUS")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            if let stats = memoryStatistics {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(stats.totalMemories)")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("Total Stored")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(stats.totalAccesses)")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("Accesses")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "%.1f", stats.averageImportance))
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("Avg Importance")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }

                /// Memory span and clear button
                HStack {
                    if let oldest = stats.oldestMemory, let newest = stats.newestMemory {
                        let span = newest.timeIntervalSince(oldest)
                        let days = Int(span / 86400)

                        HStack(spacing: 6) {
                            Image(systemName: "clock")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Memory span: \(days) days")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    Button("Clear Memories") {
                        clearConversationMemories()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Remove all stored memories from this conversation")
                }
            } else {
                Text("No memory statistics available")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var contextManagementSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("INTELLIGENCE ACTIVITY")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            if let conversation = activeConversation {
                let telemetry = conversation.settings.telemetry
                
                /// Compact 2x3 grid of stats
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        statBox(value: "\(telemetry.archiveRecallCount)", label: "Archive Recalls")
                        statBox(value: "\(telemetry.memoryRetrievalCount)", label: "Memory Searches")
                        statBox(value: "\(telemetry.compressionEventCount)", label: "Compressions")
                    }
                    
                    HStack(spacing: 12) {
                        if let context = contextStatistics {
                            statBox(value: formatTokenCount(context.currentTokenCount), label: "Active Tokens")
                        } else {
                            statBox(value: "—", label: "Active Tokens")
                        }
                        
                        if let archive = archiveStatistics, archive.totalChunks > 0 {
                            statBox(value: "\(archive.totalChunks)", label: "Archived Chunks")
                            statBox(value: formatTokenCount(archive.totalTokensArchived), label: "Archived Tokens")
                        } else {
                            statBox(value: "0", label: "Archived Chunks")
                            statBox(value: "0", label: "Archived Tokens")
                        }
                    }
                }

                /// Archive topics (if available)
                if let archive = archiveStatistics, archive.totalChunks > 0, !archive.chunks.isEmpty {
                    let topics = Set(archive.chunks.flatMap { $0.keyTopics }).prefix(5)
                    if !topics.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                        
                        HStack(spacing: 6) {
                            Image(systemName: "tag.fill")
                                .font(.caption2)
                                .foregroundColor(.blue)
                            Text("Topics: \(topics.joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .italic()
                        }
                    }
                }
            } else {
                Text("No active conversation")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    /// Helper view for compact stat boxes
    private func statBox(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.body, design: .rounded))
                .fontWeight(.semibold)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var enhancedSearchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SEARCH")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            /// Search input
            HStack {
                TextField("Search memories, context, or archives...", text: $memorySearchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        performEnhancedSearch()
                    }

                Button("Search") {
                    performEnhancedSearch()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(memorySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            /// Search mode toggles (disabled pending backend support)
            /// Note: Active and Archive search require backend API changes
            /// to support creating ConversationMemory instances from UI layer
            /*
            HStack(spacing: 12) {
                Toggle(isOn: $searchInStored) {
                    HStack(spacing: 4) {
                        Image(systemName: "tray.full")
                            .font(.caption2)
                        Text("Stored")
                            .font(.caption2)
                    }
                }
                .toggleStyle(.checkbox)
                .help("Search stored memories in vector database")

                Toggle(isOn: $searchInActive) {
                    HStack(spacing: 4) {
                        Image(systemName: "message")
                            .font(.caption2)
                        Text("Active")
                            .font(.caption2)
                    }
                }
                .toggleStyle(.checkbox)
                .help("Search current conversation messages")

                Toggle(isOn: $searchInArchive) {
                    HStack(spacing: 4) {
                        Image(systemName: "archivebox")
                            .font(.caption2)
                        Text("Archive")
                            .font(.caption2)
                    }
                }
                .toggleStyle(.checkbox)
                .help("Search archived context chunks")
            }
            .padding(.horizontal, 4)
            */

            /// Results display (enhanced to show source type)
            if !conversationMemories.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(conversationMemories) { memory in
                            EnhancedMemoryItemView(memory: memory)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(maxHeight: 200)
            } else if memorySearchQuery.isEmpty {
                Text("Enter a query and select search modes")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            } else {
                Text("No results found")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var workingDirectoryPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Working Directory")
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                /// Close button.
                Button(action: {
                    withAnimation { showingWorkingDirectoryPanel.toggle() }
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close working directory panel")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            /// Current working directory.
            if let conversation = conversationManager.activeConversation {
                VStack(alignment: .leading, spacing: 8) {
                    /// Shared topic indicator (when enabled)
                    if conversation.settings.useSharedData,
                       let topicName = conversation.settings.sharedTopicName {
                        HStack(spacing: 6) {
                            Image(systemName: "tray.full")
                                .font(.caption2)
                                .foregroundColor(.mint)
                            Text("Shared Topic: \(topicName)")
                                .font(.caption)
                                .foregroundColor(.mint)
                        }
                    }

                    Text(conversation.settings.useSharedData ? "Current Directory (Shared):" : "Current Directory:")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text(conversationManager.getEffectiveWorkingDirectory(for: conversation))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(conversation.settings.useSharedData ? .mint : .primary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(conversation.settings.useSharedData ?
                            Color.mint.opacity(0.05) : Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(conversation.settings.useSharedData ? Color.mint.opacity(0.3) : Color.clear, lineWidth: 1)
                        )

                    Text(conversation.settings.useSharedData ?
                        "Using shared topic workspace. All file operations use this shared directory across conversations." :
                        "All file operations and terminal commands will use this directory unless an absolute path is specified.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(3)

                    HStack(spacing: 8) {
                        Button("Change...") {
                            selectWorkingDirectory()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Choose a different folder for SAM to work in")
                        .disabled(conversation.settings.useSharedData)

                        Button("Reveal in Finder") {
                            revealWorkingDirectoryInFinder()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Open this folder in Finder")

                        Button(conversation.settings.useSharedData ? "Disable Shared Topic" : "Reset to Default") {
                            if conversation.settings.useSharedData {
                                // Disable shared data
                                useSharedData = false
                                conversationManager.detachSharedTopic()
                                syncSettingsToConversation()
                            } else {
                                resetWorkingDirectoryToDefault()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(conversation.settings.useSharedData ?
                            "Switch back to conversation-specific directory" :
                            "Return to using your home directory")
                    }
                }
                .padding(.horizontal, 16)
            } else {
                Text("No active conversation")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    private var chatHeader: some View {
        VStack(spacing: 0) {
            /// Conversation Info Header (when available).
            if let conversation = activeConversation {
                VStack(alignment: .leading, spacing: 0) {
                    /// Line 1: Title + Shared indicator with topic name
                    HStack {
                        /// Subagent indicator icon
                        if conversation.isSubagent {
                            Image(systemName: "person.2.circle.fill")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                        }

                        Text(conversation.title)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                            .contextMenu {
                                conversationHeaderContextMenu(conversation)
                            }

                        Spacer()

                        /// Active mini-prompts (when sidebar closed) - shown on same line as title
                        if !showingMiniPrompts {
                            let miniPromptManager = MiniPromptManager.shared
                            let enabledPrompts = miniPromptManager.miniPrompts
                                .filter { conversation.enabledMiniPromptIds.contains($0.id) }
                                .sorted { $0.displayOrder < $1.displayOrder }

                            if !enabledPrompts.isEmpty {
                                let promptNames = enabledPrompts.map { $0.name }.joined(separator: ", ")
                                let displayText = promptNames.count > 80 ? String(promptNames.prefix(80)) + "..." : promptNames

                                Text(displayText)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        /// Shared topic indicator with topic name
                        if conversation.settings.useSharedData {
                            HStack(spacing: 4) {
                                Image(systemName: "link.circle.fill")
                                    .foregroundColor(.mint)
                                if let topicName = conversation.settings.sharedTopicName {
                                    Text(topicName)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else {
                                    Text("Shared")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        /// Working indicator for active subagents
                        if conversation.isSubagent && conversation.isWorking {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                                Text("Working")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                    }

                    /// Line 2: Message count, ID, provider status
                    HStack(spacing: 12) {
                        /// Message count
                        HStack(spacing: 4) {
                            Image(systemName: "message.fill")
                                .font(.caption)
                            Text("\(conversation.messages.count) messages")
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)

                        /// Conversation ID (full, selectable)
                        Text("ID: \(conversation.id.uuidString)")
                            .font(.system(.caption2, design: .monospaced))
                            .fontWeight(.regular)
                            .foregroundColor(.secondary.opacity(0.7))
                            .textSelection(.enabled)

                        Spacer()

                        /// Provider quota status (GitHub Copilot only)
                        /// Show cost for all models, quota status only for Copilot
                        let isGitHubCopilot = selectedModel.starts(with: "github_copilot/")

                        HStack(spacing: 4) {
                            /// Cost display (always shown)
                            Group {
                                /// Format cost with "per 1M" suffix for pricing display
                                let formattedCost: String = {
                                    if currentModelCost == "0x" || currentModelCost.hasSuffix("x") {
                                        return currentModelCost  // Keep multiplier format as-is
                                    } else if currentModelCost.contains("/") {
                                        return "\(currentModelCost)/1M"  // Add per-million suffix
                                    } else {
                                        return currentModelCost
                                    }
                                }()
                                
                                Text("Cost: \(formattedCost)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .help(currentModelCost.contains("/") 
                                ? "Cost per million tokens (input/output)"
                                : "Cost multiplier (0x = free)")

                            /// Quota status (GitHub Copilot only)
                            if isGitHubCopilot, let quotaInfo = endpointManager.getGitHubCopilotQuotaInfo() {
                                let percentUsed = 100.0 - quotaInfo.percentRemaining
                                Text("Status: \(quotaInfo.used)/\(quotaInfo.entitlement) Used: \(String(format: "%.1f%%", percentUsed))")
                                    .font(.caption)
                                    .foregroundColor(percentUsed >= 90 ? .red : percentUsed >= 80 ? .orange : .secondary)
                            }
                        }
                    }
                    .padding(.top, 4)  /// Space from Line 1 (or Line 2 if shown)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(NSColor.windowBackgroundColor))
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(Color(NSColor.separatorColor)),
                    alignment: .bottom
                )
            }
        }
    }

    /// Chat management functions moved to context menu or main menu bar.

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let activeConv = activeConversation {
                    messagesVStack(for: activeConv)
                        .id(activeConv.id)  /// Force recreation only when conversation changes
                }
            }
            .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
            .onChange(of: messages.count) { _, _ in
                /// UNIFIED SCROLL HANDLER: Consolidate all scroll triggers here
                /// Previous bug: separate onChange handlers competed, causing bounce
                /// 
                /// This handler fires when:
                /// 1. New message added (user, assistant, tool, thinking)
                /// 2. Message removed (rare)
                ///
                /// Handles both new messages AND streaming (via debounced task)
                guard scrollLockEnabled, let lastMessage = messages.last else { return }

                /// Skip if already scrolling to this message (prevents duplicate calls)
                if lastScrolledToId == lastMessage.id && !lastMessage.isStreaming {
                    return
                }

                performThrottledScroll(proxy: proxy, to: lastMessage)
            }
            .onChange(of: messages.last?.content.count) { _, _ in
                /// STREAMING CONTENT UPDATE: Only fires during active streaming
                /// Debounced to prevent layout thrashing in long conversations
                guard scrollLockEnabled,
                      let lastMessage = messages.last,
                      lastMessage.isStreaming else { return }

                performThrottledScroll(proxy: proxy, to: lastMessage)
            }
            .onChange(of: messages.last?.type) { _, newType in
                /// TOOL CARD SCROLL: When a tool execution message becomes the last message,
                /// scroll to make it visible. This handles tool cards that weren't scrolled
                /// because messages.count doesn't change when tool result is added to existing card.
                guard scrollLockEnabled,
                      let lastMessage = messages.last,
                      newType == .toolExecution || newType == .thinking else { return }

                performThrottledScroll(proxy: proxy, to: lastMessage)
            }
            .onChange(of: messages) { _, newMessages in
                /// PERFORMANCE FIX: Cache tool hierarchy when messages change
                /// Prevents expensive recalculation on every view recomputation (e.g., typing)
                cachedToolHierarchy = buildToolHierarchy(messages: newMessages)

                /// PERFORMANCE: Prune stale entries from cleaned message cache
                /// Only keep cache entries for messages that still exist
                let currentMessageIds = Set(newMessages.map { $0.id })
                cachedCleanedMessages = cachedCleanedMessages.filter { currentMessageIds.contains($0.key) }
            }
            .onAppear {
                /// Store scroll proxy for keyboard navigation
                scrollProxy = proxy
            }
            .onReceive(NotificationCenter.default.publisher(for: .scrollToTop)) { _ in
                /// Scroll to first message in conversation
                if let firstMessage = messages.first {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(firstMessage.id.uuidString, anchor: .top)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .scrollToBottom)) { _ in
                /// Scroll to bottom of conversation
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo("scroll-bottom-anchor", anchor: .bottom)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .pageUp)) { _ in
                /// Page up - scroll up by approximately one screen
                /// Find a message roughly one screen up from current position
                pageScroll(proxy: proxy, direction: .up)
            }
            .onReceive(NotificationCenter.default.publisher(for: .pageDown)) { _ in
                /// Page down - scroll down by approximately one screen
                pageScroll(proxy: proxy, direction: .down)
            }
        }
    }

    /// Direction for page scrolling
    private enum PageDirection {
        case up, down
    }

    /// Page scroll by approximately one screen worth of messages
    private func pageScroll(proxy: ScrollViewProxy, direction: PageDirection) {
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

    /// Unified scroll handler with throttling and collision prevention
    /// Prevents scroll bounce by:
    /// 1. Blocking concurrent scroll operations (isScrolling flag)
    /// 2. Throttling to max 10 scrolls/second (100ms interval)
    /// 3. Cancelling pending scroll if new one requested
    /// 4. Using stable bottom anchor for streaming, message top for user messages
    ///
    /// LARGE MESSAGE FIX: When a user sends a message larger than the viewport,
    /// scrolling to the bottom causes the top to be off-screen and LazyVStack
    /// may not render it. For user messages, we scroll to the TOP of the message
    /// so it renders properly. For streaming assistant messages, we scroll to bottom.
    private func performThrottledScroll(proxy: ScrollViewProxy, to message: EnhancedMessage) {
        /// Prevent concurrent scroll operations
        guard !isScrolling else { return }

        let now = Date()
        let timeSinceLastScroll = now.timeIntervalSince(lastScrollTime)

        /// Determine scroll target based on message type
        /// - User messages: scroll to TOP of message (ensures large messages render from top)
        /// - Streaming messages: scroll to bottom anchor (content grows downward)
        /// - Tool execution messages: scroll to bottom anchor (content grows as tool runs)
        /// - Thinking messages: scroll to bottom anchor (content grows during thinking)
        /// - Assistant messages (non-streaming): scroll to TOP (like user messages)
        let scrollToMessageTop = message.type == .user ||
            (!message.isStreaming && message.type == .assistant && message.type != .toolExecution && message.type != .thinking)

        if timeSinceLastScroll >= 0.1 {
            /// Enough time passed - scroll immediately
            isScrolling = true
            lastScrollTime = now
            lastScrolledToId = message.id

            if scrollToMessageTop {
                /// LARGE MESSAGE FIX: Scroll to the TOP of the message
                /// This ensures LazyVStack renders the message from the visible top portion
                /// Uses the message's stable ID with .top anchor
                proxy.scrollTo(message.id.uuidString, anchor: .top)
            } else {
                /// STREAMING FIX: Scroll to stable bottom anchor
                /// The anchor position doesn't change when message content updates
                /// This prevents the bounce caused by content size recalculation
                proxy.scrollTo("scroll-bottom-anchor", anchor: .bottom)
            }

            /// Clear isScrolling after a short delay
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                await MainActor.run { isScrolling = false }
            }
        } else {
            /// Too soon - debounce with pending task
            pendingScrollTask?.cancel()
            pendingScrollTask = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !isScrolling else { return }

                    /// Re-check conditions after delay
                    guard let currentLast = messages.last else { return }

                    isScrolling = true
                    lastScrollTime = Date()
                    lastScrolledToId = currentLast.id

                    /// Re-determine scroll target with current message state
                    /// Tool execution and thinking messages should scroll to bottom (content grows)
                    let scrollToTop = currentLast.type == .user ||
                        (!currentLast.isStreaming && currentLast.type == .assistant && currentLast.type != .toolExecution && currentLast.type != .thinking)

                    if scrollToTop {
                        proxy.scrollTo(currentLast.id.uuidString, anchor: .top)
                    } else {
                        proxy.scrollTo("scroll-bottom-anchor", anchor: .bottom)
                    }

                    Task {
                        try? await Task.sleep(for: .milliseconds(50))
                        await MainActor.run { isScrolling = false }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func messagesVStack(for conversation: ConversationModel) -> some View {
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
                                /// LAZYVSTACK RENDER FIX (v2): Force intrinsic content height calculation
                                /// minHeight: 1 alone doesn't work because LazyVStack may defer rendering
                                /// until the view enters the visible area, causing empty placeholders
                                /// 
                                /// Solution: Use .fixedSize to force immediate size calculation,
                                /// combined with minHeight for edge cases (empty content)
                                /// This ensures SwiftUI measures actual content before display
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(minHeight: 24) /// Minimum reasonable message height
                                .id(viewID)
                            } else {
                                /// PERFORMANCE: Removed filter logging (fired on every render)
                                EmptyView()
                            }
                        }
                    }

                    /// SCROLL ANCHOR: Invisible view at the very bottom of message list
                    /// Scrolling to this provides more stable behavior than scrolling to last message
                    /// because its position doesn't change when message content updates
                    Color.clear
                        .frame(height: 1)
                        .id("scroll-bottom-anchor")
                }
                .id("messages-\(enableAnimations)")
                .padding(.horizontal)  /// Only horizontal padding, no bottom padding
                .padding(.top)
    }

    private var messageInput: some View {
        VStack(spacing: 0) {
            /// Expanded parameter controls (moved from top configuration panel).
            parameterControlsPanel

            Divider()

            /// Show SD-specific UI or standard message input based on mode.
            if isStableDiffusionOnlyMode {
                stableDiffusionInputUI
            } else {
                standardMessageInputUI
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    /// Standard text input for LLM chat.
    private var standardMessageInputUI: some View {
        VStack(spacing: 0) {
            /// Dynamic input area with stacked control buttons.
            HStack(alignment: .bottom, spacing: 12) {
                /// Multi-line text input with fixed 4-line height.
                ZStack(alignment: .topLeading) {
                    TextEditor(text: Binding(
                        get: { messageText },
                        set: { newValue in
                            // Prevent typing if model not loaded
                            if endpointManager.isLocalModel(selectedModel) && !isLocalModelLoaded {
                                logger.warning("BLOCKED: Cannot type when model not loaded")
                                return
                            }
                            messageText = newValue
                        }
                    ))
                        .font(.body)
                        .disabled(shouldDisableInput || (isSending && !isAwaitingUserInput))
                        .scrollContentBackground(.hidden)
                        .background(
                            isAwaitingUserInput
                                ? Color(NSColor.controlBackgroundColor).opacity(0.95)
                                : Color(NSColor.controlBackgroundColor)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    isAwaitingUserInput
                                        ? Color.blue.opacity(0.6)
                                        : Color(NSColor.separatorColor),
                                    lineWidth: isAwaitingUserInput ? 2 : 1
                                )
                        )
                        .frame(minHeight: 45, maxHeight: 120)
                        .focused($isInputFocused)
                        .onChange(of: messageText) { oldValue, newValue in
                            /// Prevent typing if model not loaded
                            if shouldDisableInput && newValue != oldValue {
                                logger.warning("BLOCKED TYPING: shouldDisableInput=true, reverting '\(newValue)' to '\(oldValue)'")
                                messageText = oldValue
                                return
                            }
                            /// Keep bridge in sync for voice manager readback
                            voiceBridge.currentMessageText = newValue

                            /// FEATURE: Auto-save draft message to conversation with debounced disk persistence
                            /// Save whenever text changes so it persists even if user quits app
                            if let conversation = activeConversation, newValue != conversation.settings.draftMessage {
                                conversation.settings.draftMessage = newValue

                                /// Cancel previous save task and schedule new one (debounce)
                                draftSaveTask?.cancel()
                                draftSaveTask = Task {
                                    /// Wait 500ms before saving to disk (debounce rapid typing)
                                    try? await Task.sleep(nanoseconds: 500_000_000)
                                    guard !Task.isCancelled else { return }
                                    await MainActor.run {
                                        conversationManager.saveConversations()
                                        logger.debug("DRAFT_PERSIST: Saved draft to disk (\(newValue.count) chars)")
                                    }
                                }
                            }
                        }
                        .onKeyPress { keyPress in
                            /// Handle Enter key behavior based on modifiers.
                            if keyPress.key == .return {
                                /// Shift+Enter: Insert newline (allow default behavior) Note: Cmd+Enter doesn't work reliably in SwiftUI TextEditor, use Shift+Enter instead.
                                if keyPress.modifiers.contains(.shift) {
                                    return .ignored
                                } else {
                                    /// Plain Enter: Send message.
                                    if isAwaitingUserInput {
                                        submitUserResponse()
                                    } else if !isSending && !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        sendMessage()
                                    }
                                    return .handled
                                }
                            }
                            return .ignored
                        }

                    /// Placeholder text or collaboration prompt.
                    if messageText.isEmpty {
                        if isAwaitingUserInput {
                            /// Show simple waiting indicator instead of full prompt (agent's prompt now appears as a message in the chat above).
                            HStack {
                                Image(systemName: "hourglass")
                                    .foregroundColor(.blue)
                                Text("Agent is waiting for your response...")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                            }
                            .padding(8)
                            .allowsHitTesting(false)
                        } else if isStableDiffusionOnlyMode {
                            /// Show SD-specific prompt placeholder.
                            HStack {
                                Image(systemName: "photo")
                                    .foregroundColor(.purple)
                                Text("Describe the image you want to generate...")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                            }
                            .padding(8)
                            .allowsHitTesting(false)
                        } else if endpointManager.isLocalModel(selectedModel) && !isLocalModelLoaded {
                            /// Show instruction to load local model.
                            HStack {
                                Image(systemName: "play.fill")
                                    .foregroundColor(.orange)
                                Text("Click Load Model button above to start chatting")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                            }
                            .padding(8)
                            .allowsHitTesting(false)
                        } else {
                            /// Show placeholder with voice or keyboard instructions
                            if voiceManager.listeningMode {
                                Text("Say \"Hey SAM\" and wait for chime, or type your message\n(Enter to send, Shift+Enter for newline)")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                                    .allowsHitTesting(false)
                                    .padding(8)
                            } else {
                                Text("Ask SAM anything...\n(Enter to send, Shift+Enter for newline)")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                                    .allowsHitTesting(false)
                                    .padding(8)
                            }
                        }
                    }
                }

                /// Voice control buttons (speaker and microphone).
                VStack(spacing: 8) {
                    /// Paperclip button (top) - attach files to conversation.
                    Button(action: {
                        attachFiles()
                    }) {
                        Image(systemName: attachedFiles.isEmpty ? "paperclip" : "paperclip.badge.ellipsis")
                            .foregroundColor(attachedFiles.isEmpty ? .secondary : .accentColor)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.bordered)
                    .frame(width: 36)
                    .fixedSize()
                    .help(attachedFiles.isEmpty ? "Attach files to conversation" : "Attached files: \(attachedFiles.count)")

                    /// Speaker button - toggles speaking mode.
                    Button(action: {
                        voiceManager.toggleSpeaking()
                    }) {
                        Image(systemName: voiceManager.speakingMode ? "speaker.fill" : "speaker")
                            .foregroundColor(voiceManager.speakingMode ? .accentColor : .secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.bordered)
                    .frame(width: 36)
                    .fixedSize()
                    .help("Toggle speaking mode: SAM will read responses aloud")

                    /// Microphone button (middle) - toggles listening mode.
                    Button(action: {
                        voiceManager.toggleListening()
                    }) {
                        Image(systemName: voiceManager.listeningMode ? "mic.fill" : "mic")
                            .foregroundColor(
                                voiceManager.currentState == .activeListening ? .red :
                                voiceManager.listeningMode ? .accentColor : .secondary
                            )
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.bordered)
                    .frame(width: 36)
                    .fixedSize()
                    .help("Toggle listening mode: Voice control with wake word detection")
                    .disabled(shouldDisableInput)

                    /// Send/Stop button (bottom) - play.fill for send, stop.fill for cancel.
                    Button(action: {
                        if isAwaitingUserInput {
                            submitUserResponse()
                        } else if isSending {
                            streamingTask?.cancel()
                            streamingTask = nil
                            isSending = false
                            currentOrchestrator?.cancelWorkflow()
                            currentOrchestrator = nil
                            if let conversation = activeConversation {
                                conversation.isProcessing = false
                            }
                            Task {
                                await endpointManager.cancelLocalModelGeneration()
                            }
                        } else {
                            sendMessage()
                        }
                    }) {
                        if isAwaitingUserInput {
                            Image(systemName: "play.fill")
                                .foregroundColor(.accentColor)
                                .frame(width: 20, height: 20)
                        } else if isSending {
                            Image(systemName: "stop.fill")
                                .foregroundColor(.red)
                                .frame(width: 20, height: 20)
                        } else if isStableDiffusionOnlyMode {
                            Image(systemName: "photo.fill")
                                .foregroundColor(.blue)
                                .frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "play.fill")
                                .foregroundColor(.secondary)
                                .frame(width: 20, height: 20)
                        }
                    }
                    .buttonStyle(.bordered)
                    .frame(width: 36)
                    .fixedSize()
                    .disabled(
                        (!isAwaitingUserInput && !isSending && messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ||
                        shouldDisableInput
                    )
                    .help(
                        isAwaitingUserInput ? "Submit response" :
                        isSending ? "Stop generation" :
                        isStableDiffusionOnlyMode ? "Generate image" :
                        "Send message"
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    /// Available image sizes based on selected SD model
    /// NOTE: UI picker stores user preference, but actual dimension support depends on Core ML model capabilities.
    /// Future enhancement: Query Core ML model metadata to get truly supported dimensions.
    /// Current implementation provides common sizes based on model type (SD 1.5 vs SDXL).

    /// Get model info for currently selected SD model (local or ALICE remote)
    private var currentSDModelInfo: StableDiffusionModelManager.ModelInfo? {
        /// Handle both local SD models (sd/) and ALICE remote models (alice-)
        let isLocalSD = selectedModel.hasPrefix("sd/")
        let isAliceSD = selectedModel.hasPrefix("alice-")
        guard isLocalSD || isAliceSD else { return nil }

        /// Extract model ID for lookup
        let modelId: String
        if isAliceSD {
            /// ALICE format: alice-sd-model-name - use as-is (matches createRemoteModelInfo ID)
            modelId = selectedModel
        } else {
            /// Local format: sd/model-name - extract model name
            modelId = selectedModel.replacingOccurrences(of: "sd/", with: "")
        }

        /// Get model info - check both local and ALICE models
        var models = sdModelManager.listInstalledModels()

        /// Add ALICE models if connected
        if let aliceProvider = ALICEProvider.shared, aliceProvider.isHealthy {
            let aliceModels = aliceProvider.availableModels.map { alice in
                StableDiffusionModelManager.createRemoteModelInfo(
                    aliceModelId: alice.id,
                    displayName: alice.displayName,
                    isSDXL: alice.isSDXL
                )
            }
            models.append(contentsOf: aliceModels)
        }

        logger.debug("currentSDModelInfo: Looking for '\(modelId)' in \(models.count) models")

        /// Match by ID or by name for local models
        let found = models.first(where: {
            $0.id == modelId
        })
        if let found = found {
            logger.debug("currentSDModelInfo: Found model '\(found.id)' hasCoreML=\(found.hasCoreML) hasSafeTensors=\(found.hasSafeTensors) pipelineType=\(found.pipelineType) isRemote=\(found.isRemote)")
        } else {
            logger.warning("currentSDModelInfo: Model '\(modelId)' not found in SD models. Available IDs: \(models.map { $0.id }.joined(separator: ", "))")
        }

        return found
    }

    /// Detect if current model is Z-Image (or Qwen-Image)
    private var isZImageModel: Bool {
        guard let modelInfo = currentSDModelInfo else { return false }
        return modelInfo.pipelineType.lowercased().contains("zimage") ||
               modelInfo.pipelineType.lowercased().contains("qwenimage")
    }

    /// Detect if current model is SDXL
    /// SDXL models require special handling:
    /// - EDMDPMSolverMultistepScheduler produces garbage on MPS
    /// - Need to switch to Euler scheduler for reliable results
    private var isSDXLModel: Bool {
        guard let modelInfo = currentSDModelInfo else {
            /// Fallback to name-based detection
            return selectedModel.lowercased().contains("xl") || selectedModel.lowercased().contains("sdxl")
        }
        return modelInfo.pipelineType == "StableDiffusionXL"
    }

    /// Get guidance scale range based on model type
    private var guidanceScaleRange: ClosedRange<Int> {
        if isZImageModel {
            return 0...5  /// Z-Image uses low guidance (0.0-5.0)
        } else {
            return 1...20  /// Standard SD models (1-20)
        }
    }

    /// Get default guidance scale based on model type
    private var defaultGuidanceScale: Int {
        if isZImageModel {
            return 0  /// Z-Image works best with 0.0 guidance
        } else {
            return 8  /// Standard SD default
        }
    }

    /// Get default steps based on model type
    private var defaultSteps: Int {
        if isZImageModel {
            /// Z-Image turbo models use 8-9 steps, standard uses ~50
            if let modelInfo = currentSDModelInfo, modelInfo.name.lowercased().contains("turbo") {
                return 8
            } else {
                return 50
            }
        } else {
            return 25  /// Standard SD default
        }
    }

    private var availableImageSizes: [String] {
        /// Z-Image models support 1024×1024 and higher, divisible by 16
        if isZImageModel {
            return [
                "1024×1024",
                "1152×896",
                "896×1152",
                "1216×832",
                "832×1216",
                "1344×768",
                "768×1344",
                "1536×640",
                "640×1536"
            ]
        }

        /// Determine model type from selectedModel
        let isSDXL = selectedModel.lowercased().contains("xl") || selectedModel.lowercased().contains("sdxl")

        if isSDXL {
            /// SDXL models support 1024×1024 and common SDXL ratios
            return [
                "1024×1024",
                "1152×896",
                "896×1152",
                "1216×832",
                "832×1216",
                "1344×768",
                "768×1344",
                "1536×640",
                "640×1536"
            ]
        } else {
            /// SD 1.5 and 2.x models support 512×512 and common ratios
            return [
                "512×512",
                "512×768",
                "768×512",
                "640×512",
                "512×640",
                "768×768"
            ]
        }
    }

    /// Detect current image orientation
    private var currentImageOrientation: String {
        if sdImageWidth == sdImageHeight {
            return "Square"
        } else if sdImageWidth > sdImageHeight {
            return "Landscape"
        } else {
            return "Portrait"
        }
    }

    /// Toggle image orientation (swap width/height)
    private func toggleImageOrientation() {
        /// Don't toggle square images
        guard sdImageWidth != sdImageHeight else { return }

        /// Swap width and height
        let temp = sdImageWidth
        sdImageWidth = sdImageHeight
        sdImageHeight = temp

        /// Sync to conversation settings
        syncSettingsToConversation()

        logger.debug("Toggled image orientation: \(currentImageOrientation) (\(sdImageWidth)×\(sdImageHeight))")
    }

    /// Stable Diffusion-specific input UI with parameter controls.
    private var stableDiffusionInputUI: some View {
        VStack(spacing: 6) {
            /// TOP ROW: Model/Engine + Image upload (left) + Prompts (right)
            HStack(alignment: .top, spacing: 12) {
                /// LEFT: Model/Engine selector + Image upload (Python only)
                VStack(alignment: .leading, spacing: 8) {
                    /// Model and Engine selection (compact, on same row)
                    HStack(spacing: 12) {
                        /// Engine selector
                        HStack(spacing: 6) {
                            Text("Engine:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize()

                            Menu {
                                if currentSDModelInfo?.hasCoreML ?? false {
                                    Button(action: { sdEngine = "coreml" }) {
                                        Text("CoreML")
                                            .font(.system(.caption, design: .monospaced))
                                    }
                                }
                                if currentSDModelInfo?.hasSafeTensors ?? false {
                                    Button(action: { sdEngine = "python" }) {
                                        Text("Python")
                                            .font(.system(.caption, design: .monospaced))
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(sdEngine == "coreml" ? "CoreML" : "Python")
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.down")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .frame(width: 100)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(5)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                                )
                            }
                            .disabled(!((currentSDModelInfo?.hasCoreML ?? false) && (currentSDModelInfo?.hasSafeTensors ?? false)))
                            .onChange(of: sdEngine) { _, newValue in
                                /// When switching engines, update scheduler to a compatible default
                                if newValue == "coreml" {
                                    sdScheduler = "dpm++"
                                    sdUseKarras = true
                                    /// Clear img2img parameters when switching to CoreML (not supported)
                                    sdInputImagePath = nil
                                } else {
                                    sdScheduler = "dpm++_sde_karras"
                                    sdUseKarras = false
                                }
                                syncSettingsToConversation()
                            }
                            .onAppear {
                                /// Auto-select available engine on first load
                                autoSelectEngine()
                            }
                            .onChange(of: selectedModel) { _, _ in
                                /// Auto-select when model changes
                                autoSelectEngine()
                            }
                        }
                    }

                    /// Image upload with strength controls (Python engine only)
                    if sdEngine == "python" {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Input Image (Optional)")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            ImageUploadView(imagePath: $sdInputImagePath)
                                .frame(width: 220)
                                .onChange(of: sdInputImagePath) { _, _ in
                                    syncSettingsToConversation()
                                }

                            /// Strength slider (only visible when image is uploaded)
                            if sdInputImagePath != nil {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 4) {
                                        Text("Strength")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Text(String(format: "%.2f", sdStrength))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .monospacedDigit()
                                    }
                                    Slider(value: $sdStrength, in: 0.0...1.0, step: 0.05)
                                        .frame(width: 220)  /// Match image preview width
                                        .onChange(of: sdStrength) { _, _ in
                                            syncSettingsToConversation()
                                        }
                                    Text("0.0=no change • 1.0=full generation")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .frame(width: 220, alignment: .leading)  /// Match width
                                }
                            }
                        }
                    }
                }

                /// RIGHT: Prompt and negative prompt
                VStack(alignment: .leading, spacing: 8) {
                    /// Main prompt field
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Prompt")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $messageText)
                                .font(.body)
                                .frame(minHeight: 60, maxHeight: 100)
                                .scrollContentBackground(.hidden)
                                .background(Color(NSColor.controlBackgroundColor))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                                )
                                .focused($isInputFocused)
                                .onSubmit {
                                    /// Enter key triggers generation if text is not empty
                                    if !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending {
                                        sendMessage()
                                    }
                                }

                            if messageText.isEmpty {
                                Text("a beautiful sunset over mountains, vibrant colors, high detail")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                                    .padding(.leading, 8)
                                    .padding(.top, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                    }

                    /// Negative prompt field
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Negative Prompt (Optional)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $sdNegativePrompt)
                                .font(.body)
                                .frame(minHeight: 60, maxHeight: 80)
                                .scrollContentBackground(.hidden)
                                .background(Color(NSColor.controlBackgroundColor))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                                )
                                .onChange(of: sdNegativePrompt) { _, _ in
                                    syncSettingsToConversation()
                                }

                            if sdNegativePrompt.isEmpty {
                                Text("ugly, blurry, low quality, distorted")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                                    .padding(.leading, 8)
                                    .padding(.top, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
            }

            /// BOTTOM ROW: Parameter controls (Steps, CFG, Scheduler, Size, Upscale, Count, Seed, Generate button)
            HStack(spacing: 16) {
                /// Steps.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Steps")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
                        TextField("", value: $sdSteps, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .onChange(of: sdSteps) { _, _ in
                                syncSettingsToConversation()
                            }
                        Stepper("", value: $sdSteps, in: 1...100)
                            .labelsHidden()
                    }
                }

                /// CFG Scale (formerly Guidance).
                VStack(alignment: .leading, spacing: 4) {
                    Text("CFG Scale")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
                        TextField("", value: $sdGuidanceScale, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .onChange(of: sdGuidanceScale) { _, _ in
                                syncSettingsToConversation()
                            }
                        Stepper("", value: $sdGuidanceScale, in: guidanceScaleRange)
                            .labelsHidden()
                    }
                }

                /// Scheduler.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scheduler")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SDSchedulerPickerView(
                        selectedScheduler: $sdScheduler,
                        engine: sdEngine,
                        useKarras: $sdUseKarras
                    )
                    .onChange(of: sdScheduler) { _, _ in
                        syncSettingsToConversation()
                    }
                    .onChange(of: sdUseKarras) { _, _ in
                        syncSettingsToConversation()
                    }
                }

                /// Device (Python engine only)
                if sdEngine == "python" {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Device")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        SDDevicePickerView(selectedDevice: $sdDevice)
                            .onChange(of: sdDevice) { _, _ in
                                syncSettingsToConversation()
                            }
                    }
                }

                /// Image size.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Size")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 6) {
                        SDSizePickerView(
                            selectedSize: Binding(
                                get: { "\(sdImageWidth)×\(sdImageHeight)" },
                                set: { newValue in
                                    let components = newValue.split(separator: "×")
                                    if components.count == 2,
                                       let width = Int(components[0]),
                                       let height = Int(components[1]) {
                                        sdImageWidth = width
                                        sdImageHeight = height
                                        syncSettingsToConversation()
                                    }
                                }
                            ),
                            availableSizes: availableImageSizes
                        )

                        /// Portrait/Landscape toggle button
                        Button(action: toggleImageOrientation) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.left.arrow.right")
                                    .font(.caption)
                                Text(currentImageOrientation)
                                    .font(.caption)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .disabled(sdImageWidth == sdImageHeight)  /// Disable for square images
                        .help(sdImageWidth == sdImageHeight ? "Square images cannot be rotated" : "Toggle between portrait and landscape orientation")
                    }
                }

                /// Upscaling model
                VStack(alignment: .leading, spacing: 4) {
                    Text("Upscale")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    UpscaleModelPickerView(selectedModel: $sdUpscaleModel)
                        .onChange(of: sdUpscaleModel) { _, _ in
                            syncSettingsToConversation()
                        }
                }

                /// Image count.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Count")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
                        TextField("", value: $sdImageCount, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)
                            .onChange(of: sdImageCount) { _, _ in
                                syncSettingsToConversation()
                            }
                        Stepper("", value: $sdImageCount, in: 1...10)
                            .labelsHidden()
                    }
                }

                /// Seed (up to 10 digits).
                VStack(alignment: .leading, spacing: 4) {
                    Text("Seed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("-1 = random", value: $sdSeed, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .onChange(of: sdSeed) { _, _ in
                            syncSettingsToConversation()
                        }
                }

                Spacer()

                /// Generate/Stop button aligned with bottom row.
                VStack(alignment: .leading, spacing: 4) {
                    Text(" ")
                        .font(.caption)
                        .foregroundColor(.clear)
                    Button(action: {
                        if !isSending {
                            sendMessage()
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: isSending ? "hourglass" : "play.fill")
                            Text(isSending ? "Generating..." : "Generate")
                        }
                        .font(.body)
                    }
                    .buttonStyle(.bordered)
                    .help(isSending ? "Generation in progress" : "Generate image (or press Enter)")
                    .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Parameter Controls Panel

    private var parameterControlsPanel: some View {
        VStack(spacing: 0) {
            /// FIRST ROW: Model, Prompt, Tools, Actions.
            HStack(spacing: 12) {
                /// Model selection.
                HStack(spacing: 6) {
                    Text("Model:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize()
                        .help("Select the AI model to use for this conversation. Local models require loading before use.")

                    ModelPickerView(
                        selectedModel: $selectedModel,
                        models: availableModels,
                        endpointManager: endpointManager
                    )
                    .frame(minWidth: 150, idealWidth: 200)

                    /// Load/Eject buttons for local models only.
                    if endpointManager.isLocalModel(selectedModel) {
                        /// Check loading status directly from endpointManager (more reliable than @State)
                        let currentStatus = endpointManager.modelLoadingStatus[selectedModel] ?? .notLoaded

                        switch currentStatus {
                        case .loading:
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 16, height: 16)
                        case .loaded:
                            Button(action: { ejectLocalModel() }) {
                                Image(systemName: "eject.fill")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .help("Eject model from memory")
                        case .notLoaded:
                            Button(action: { loadLocalModel() }) {
                                Image(systemName: "play.fill")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .help("Load model into memory")
                        }
                    }
                }

                /// System prompt selection.
                HStack(spacing: 6) {
                    Text("Prompt:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .help("Select a system prompt to guide the AI's behavior and capabilities.")

                    /// Get conversation-scoped configurations (defaults + workspace + user).
                    let conversationConfigs = systemPromptManager.configurationsForConversation(
                        workspacePath: conversationManager.activeConversation?.workingDirectory
                    )

                    if !conversationConfigs.isEmpty, let activeConv = conversationManager.activeConversation {
                        /// Use a local binding that ensures non-nil value.
                        let binding = Binding<UUID>(
                            get: {
                                activeConv.settings.selectedSystemPromptId
                                ?? conversationConfigs.first?.id
                                ?? UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
                            },
                            set: { newValue in
                                /// Update conversation's selected prompt directly.
                                if var conv = conversationManager.activeConversation {
                                    conv.settings.selectedSystemPromptId = newValue

                                    /// Auto-enable/disable settings based on prompt configuration
                                    if let config = conversationConfigs.first(where: { $0.id == newValue }) {
                                        /// Workflow Mode: Enable if prompt requires it, disable if not
                                        if config.autoEnableWorkflowMode {
                                            conv.settings.enableWorkflowMode = true
                                            enableWorkflowMode = true
                                        } else if conv.settings.enableWorkflowMode {
                                            /// Auto-disable if switching to non-workflow prompt
                                            conv.settings.enableWorkflowMode = false
                                            enableWorkflowMode = false
                                        }

                                        /// Terminal: Enable if tools available AND prompt requires it, disable otherwise
                                        if config.autoEnableTerminal {
                                            let toolsAvailable = enableTools || userManuallyEnabledTools
                                            let isLocal = endpointManager.isLocalModel(selectedModel)

                                            if toolsAvailable && (!isLocal || userManuallyEnabledTools) {
                                                conv.settings.enableTerminalAccess = true
                                                enableTerminalAccess = true
                                            } else {
                                                logger.info("CHATWIDGET: Skipped auto-enable terminal - tools not available (model: \(selectedModel), toolsEnabled: \(enableTools), isLocal: \(isLocal))")
                                            }
                                        } else if conv.settings.enableTerminalAccess {
                                            /// Auto-disable terminal if switching to non-terminal prompt
                                            conv.settings.enableTerminalAccess = false
                                            enableTerminalAccess = false
                                        }

                                        /// Dynamic Iterations: Enable if prompt requires it, disable if not
                                        if config.autoEnableDynamicIterations {
                                            conv.settings.enableDynamicIterations = true
                                            enableDynamicIterations = true
                                        } else if conv.settings.enableDynamicIterations {
                                            /// Auto-disable if switching to non-dynamic-iterations prompt
                                            conv.settings.enableDynamicIterations = false
                                            enableDynamicIterations = false
                                        }
                                        /// Note: autoEnableTools would control mcpToolsEnabled in SAMConfig (global setting)
                                        /// For now, we'll skip it since tools are global, not per-conversation
                                    }

                                    conversationManager.activeConversation = conv
                                    conversationManager.saveConversations()
                                }

                                /// Also update global selection for new conversations.
                                systemPromptManager.selectedConfigurationId = newValue
                                if let config = conversationConfigs.first(where: { $0.id == newValue }) {
                                    systemPromptManager.selectConfiguration(config)
                                }
                            }
                        )

                        PromptPickerView(
                            selectedPromptId: binding,
                            prompts: conversationConfigs
                        )
                    } else {
                        Text("Loading...")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .frame(width: 140)
                    }
                }

                /// Personality selection.
                HStack(spacing: 6) {
                    Text("Personality:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .help("Select a personality to customize the AI's tone and communication style.  May provide focused knowledge in specific areas.")

                    if let activeConv = conversationManager.activeConversation {
                        PersonalityPickerView(
                            selectedPersonalityId: Binding<UUID?>(
                                get: {
                                    activeConv.settings.selectedPersonalityId
                                },
                                set: { newValue in
                                    if var conv = conversationManager.activeConversation {
                                        conv.settings.selectedPersonalityId = newValue
                                        conversationManager.activeConversation = conv
                                        conversationManager.saveConversations()
                                    }
                                }
                            )
                        )
                    } else {
                        Text("Loading...")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .frame(width: 140)
                    }
                }

                Spacer()

                /// Panel toggle buttons group.
                HStack(spacing: 6) {
                    Button(action: { showingWorkingDirectoryPanel.toggle() }) {
                        Image(systemName: "folder")
                            .foregroundColor(showingWorkingDirectoryPanel ? .accentColor : .secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.bordered)
                    .frame(width: 36)
                    .fixedSize()
                    .help("Working Directory")

                    Button(action: { showingMemoryPanel.toggle() }) {
                        Image(systemName: "brain.head.profile")
                            .foregroundColor(showingMemoryPanel ? .accentColor : .secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.bordered)
                    .frame(width: 36)
                    .fixedSize()
                    .help("Session Intelligence")

                    Button(action: { showingPerformanceMetrics.toggle() }) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .foregroundColor(showingPerformanceMetrics ? .accentColor : .secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.bordered)
                    .frame(width: 36)
                    .fixedSize()
                    .help("Performance Metrics")

                    Button(action: {
                        if enableTerminalAccess {
                            showingTerminalPanel.toggle()
                        }
                    }) {
                        Image(systemName: "terminal")
                            .foregroundColor(enableTerminalAccess ? (showingTerminalPanel ? .accentColor : .secondary) : .secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.bordered)
                    .frame(width: 36)
                    .fixedSize()
                    .disabled(!enableTerminalAccess)
                    .help(enableTerminalAccess ? "Terminal" : "Terminal (Disabled - Enable in toolbar)")
                }

                Divider()
                    .frame(height: 20)
                    .padding(.horizontal, 4)

                /// Settings and actions group.
                HStack(spacing: 6) {
                    Button(action: { withAnimation { showAdvancedParameters.toggle() } }) {
                        Image(systemName: "wrench.and.screwdriver")
                            .foregroundColor(showAdvancedParameters ? .accentColor : .secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.bordered)
                    .frame(width: 36)
                    .fixedSize()
                    .help("Parameters")

                    Button(action: { showingExportOptions.toggle() }) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundColor(showingExportOptions ? .accentColor : .secondary)
                            .frame(width: 20, height: 20)
                            .offset(y: -1)
                    }
                    .buttonStyle(.bordered)
                    .frame(width: 36)
                    .fixedSize()
                    .help("Export Chat")

                    Button(action: { showingTodoListPopover.toggle() }) {
                        ZStack {
                            Image(systemName: "list.clipboard.fill")
                                .foregroundColor(showingTodoListPopover ? .accentColor : .secondary)
                                .frame(width: 20, height: 20)

                            /// Badge showing todo count
                            if !agentTodoList.isEmpty {
                                Text("\(agentTodoList.count)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(3)
                                    .background(Circle().fill(Color.accentColor))
                                    .offset(x: 10, y: -10)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .frame(width: 36)
                    .fixedSize()
                    .help("Agent Todo List (\(agentTodoList.count) items)")
                    .popover(isPresented: $showingTodoListPopover, arrowEdge: .bottom) {
                        TodoListPopover(todos: agentTodoList)
                    }

                    Button(action: { scrollLockEnabled.toggle() }) {
                        Image(systemName: scrollLockEnabled ? "lock.fill" : "lock.open.fill")
                            .foregroundColor(scrollLockEnabled ? .accentColor : .secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.bordered)
                    .frame(width: 36)
                    .fixedSize()
                    .help(scrollLockEnabled ? "Scroll Lock: ON (auto-scroll to new messages)" : "Scroll Lock: OFF (manual scroll)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(Color(NSColor.separatorColor)),
                alignment: .bottom
            )

            /// SECOND ROW: Advanced Parameters (collapsible, responsive wrapping).
            if showAdvancedParameters {
                Divider()

                FlowLayout(spacing: 12, alignment: .leading) {
                    /// Temperature.
                    HStack(spacing: 4) {
                        Text("Temp:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize()
                        Slider(value: $temperature, in: 0.0...2.0, step: 0.1)
                            .frame(width: 60)
                        Text("\(temperature, specifier: "%.1f")")
                            .font(.caption2)
                            .monospacedDigit()
                            .frame(width: 25)
                    }
                    .help("Creativity Level: Higher values make responses more creative and varied. Lower values make responses more focused and predictable.")
                    .fixedSize()

                    /// Top-P.
                    HStack(spacing: 4) {
                        Text("Top-P:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize()
                        Slider(value: $topP, in: 0.0...1.0, step: 0.05)
                            .frame(width: 60)
                        Text("\(topP, specifier: "%.2f")")
                            .font(.caption2)
                            .monospacedDigit()
                            .frame(width: 30)
                    }
                    .help("Response Variety: Controls how diverse the AI's word choices are. Higher values allow more varied responses.")
                    .fixedSize()

                    /// Repetition Penalty (optional).
                    if let repPenalty = repetitionPenalty {
                        HStack(spacing: 4) {
                            Text("Rep:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .fixedSize()
                            Slider(value: Binding(
                                get: { repPenalty },
                                set: { repetitionPenalty = $0 }
                            ), in: 1.0...2.0, step: 0.1)
                                .frame(width: 60)
                            Text("\(repPenalty, specifier: "%.1f")")
                                .font(.caption2)
                                .monospacedDigit()
                                .frame(width: 25)
                            Button(action: { repetitionPenalty = nil }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .help("Repetition Control: Helps prevent the AI from repeating the same phrases. Higher values reduce repetition.")
                        .fixedSize()
                    } else {
                        Button(action: { repetitionPenalty = 1.1 }) {
                            HStack(spacing: 2) {
                                Image(systemName: "plus.circle")
                                    .font(.caption2)
                                Text("Rep Penalty")
                                    .font(.caption2)
                            }
                            .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                    }

                    /// Vertical divider (wrapped in container).
                    Divider()
                        .frame(width: 1, height: 20)

                    /// Reasoning toggle.
                    Toggle(isOn: $enableReasoning) {
                        Text("Reasoning")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .help("Enables or disables reasoning for models that support it.")
                    .toggleStyle(.switch)
                    .fixedSize()

                    /// Tools toggle.
                    Toggle(isOn: $enableTools) {
                        Text("Tools")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .help("Allow SAM to search the web, read files, create documents, and perform other helpful tasks")
                    .toggleStyle(.switch)
                    .fixedSize()
                    .onChange(of: enableTools) { _, newValue in
                        guard !isLoadingConversationSettings else { return }
                        if !newValue {
                            /// Tools disabled → Save terminal state and disable terminal.
                            terminalStateBeforeDisable = enableTerminalAccess
                            enableTerminalAccess = false
                        } else {
                            /// Tools enabled → Restore previous terminal state.
                            enableTerminalAccess = terminalStateBeforeDisable
                        }
                        syncSettingsToConversation()
                    }

                    /// Auto-Approve toggle (WARNING: Bypasses security).
                    Toggle(isOn: $autoApprove) {
                        Text("Auto-Approve")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .help("Allow agents to run any command without prompting. WARNING: Bypasses all security!")
                    .toggleStyle(.switch)
                    .fixedSize()

                    /// Terminal Access toggle (SECURITY: Default disabled).
                    Toggle(isOn: $enableTerminalAccess) {
                        Text("Terminal")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .help("Allow agents to use terminal commands (requires Tools)")
                    .toggleStyle(.switch)
                    .fixedSize()
                    .disabled(!enableTools)
                    .onChange(of: enableTerminalAccess) { _, _ in
                        guard !isLoadingConversationSettings else { return }
                        syncSettingsToConversation()
                    }

                    /// Workflow Mode toggle.
                    Toggle(isOn: $enableWorkflowMode) {
                        Text("Workflow")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .help("Automatically prompt the agent to continue.")
                    .toggleStyle(.switch)
                    .fixedSize()
                    .onChange(of: enableWorkflowMode) { _, _ in
                        guard !isLoadingConversationSettings else { return }
                        syncSettingsToConversation()
                    }

                    /// Shared Topic toggle.
                    Toggle(isOn: $useSharedData) {
                        Text("Shared Topic")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .help("Enable shared topics for cross-conversation memory")
                    .toggleStyle(.switch)
                    .fixedSize()
                    .onChange(of: useSharedData) { _, newValue in
                        guard !isLoadingConversationSettings else { return }
                        if newValue {
                            // Load topics when enabling
                            Task { await loadSharedTopics() }
                            // If no topic selected, auto-select first one
                            if assignedSharedTopicId == nil, let first = sharedTopics.first {
                                assignedSharedTopicId = first.id
                                conversationManager.attachSharedTopic(topicId: UUID(uuidString: first.id), topicName: first.name)
                            } else if let topicId = assignedSharedTopicId {
                                let topicName = sharedTopics.first(where: { $0.id == topicId })?.name
                                conversationManager.attachSharedTopic(topicId: UUID(uuidString: topicId), topicName: topicName)
                            }
                        } else {
                            conversationManager.detachSharedTopic()
                        }
                        syncSettingsToConversation()

                        /// Terminal directory change is now handled via notification
                        /// ConversationManager posts conversationWorkingDirectoryDidChange
                        /// TerminalManager observes and restarts session in new directory
                    }

                    /// Topic picker (visible when shared data enabled).
                    if useSharedData {
                        if sharedTopics.isEmpty {
                            /// No topics available - show button to open Preferences
                            Button(action: {
                                NotificationCenter.default.post(name: .showPreferences, object: nil)
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .font(.caption2)
                                    Text("No Topics - Create One")
                                        .font(.caption2)
                                }
                                .foregroundColor(.orange)
                            }
                            .buttonStyle(.plain)
                            .help("No shared topics available. Click to open Preferences and create a topic.")
                        } else {
                            TopicPickerView(
                                selectedTopicId: $assignedSharedTopicId,
                                topics: sharedTopics
                            )
                            .help("Select which shared topic to use for this conversation")
                            .fixedSize()
                            .onChange(of: assignedSharedTopicId) { _, newVal in
                                guard !isLoadingConversationSettings else { return }
                                if let topicId = newVal {
                                    let topicName = sharedTopics.first(where: { $0.id == topicId })?.name
                                    conversationManager.attachSharedTopic(topicId: UUID(uuidString: topicId), topicName: topicName)
                                }
                                syncSettingsToConversation()

                                /// Terminal directory change is now handled via notification
                                /// ConversationManager posts conversationWorkingDirectoryDidChange
                                /// TerminalManager observes and restarts session in new directory
                            }
                        }
                    }

                    /// Dynamic Iterations toggle.
                    Toggle(isOn: $enableDynamicIterations) {
                        Text("Extend")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .help("Allow agent to extend iteration limit when needed for complex tasks")
                    .toggleStyle(.switch)
                    .fixedSize()
                    .onChange(of: enableDynamicIterations) { _, _ in
                        guard !isLoadingConversationSettings else { return }
                        syncSettingsToConversation()
                    }
                    .onChange(of: scrollLockEnabled) { _, _ in
                        guard !isLoadingConversationSettings else { return }
                        syncSettingsToConversation()
                    }

                    /// Vertical divider (wrapped in container).
                    Divider()
                        .frame(width: 1, height: 20)

                    /// Max Tokens.
                    HStack(spacing: 4) {
                        Text("Max Tokens:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize()
                        let minTokens = 1024
                        let effectiveMaxTokens = max(minTokens + 1024, maxMaxTokens)
                        let clampedValue = min(max(minTokens, maxTokens ?? effectiveMaxTokens), effectiveMaxTokens)
                        Slider(value: Binding(
                            get: { Double(clampedValue) },
                            set: { maxTokens = Int($0) }
                        ), in: Double(minTokens)...Double(effectiveMaxTokens), step: 1024)
                            .frame(width: 80)
                        Text(maxTokens != nil ? (maxTokens! >= 1024 ? "\(maxTokens!/1024)k" : "\(maxTokens!)") : "∞")
                            .font(.caption2)
                            .monospacedDigit()
                            .frame(width: 30)
                    }
                    .fixedSize()

                    /// Context Window.
                    HStack(spacing: 4) {
                        Text("Context:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize()
                        let minContext = 2048
                        let effectiveMaxContext = max(minContext + 2048, maxContextWindowSize)
                        let clampedContext = min(max(minContext, contextWindowSize), effectiveMaxContext)
                        Slider(value: Binding(
                            get: { Double(clampedContext) },
                            set: { contextWindowSize = Int($0) }
                        ), in: Double(minContext)...Double(effectiveMaxContext), step: 1024)
                            .frame(width: 80)
                        Text("\(contextWindowSize/1024)k")
                            .font(.caption2)
                            .monospacedDigit()
                            .frame(width: 30)
                    }
                    .fixedSize()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
            }
        }
        .onAppear {
            loadGlobalMLXSettings()
            /// Initialize document import system if not already done
            if documentImportSystem == nil {
                documentImportSystem = DocumentImportSystem(conversationManager: conversationManager)
            }
        }
    }

    // MARK: - Actions

    private func syncWithActiveConversation() {
        guard let conversation = activeConversation else {
            logger.debug("MESSAGE_LIFECYCLE: syncWithActiveConversation - no active conversation")
            /// REMOVED: messages.removeAll() - messages is now computed property
            return
        }

        /// Prevent bidirectional sync loop.
        guard !isSyncingMessages else {
            logger.debug("MESSAGE_LIFECYCLE: syncWithActiveConversation - already syncing, skipping")
            return
        }

        logger.debug("MESSAGE_LIFECYCLE: syncWithActiveConversation - START (conversation messages: \(conversation.messages.count))")

        /// Set flags to prevent onChange handlers from triggering during sync.
        isLoadingConversationSettings = true
        isSyncingMessages = true
        defer {
            isLoadingConversationSettings = false
            isSyncingMessages = false
            logger.debug("MESSAGE_LIFECYCLE: syncWithActiveConversation - END")
        }

        /// REMOVED: Message syncing - messages is now computed property reading activeConversation?.messages
        /// ConversationModel.messages auto-syncs FROM MessageBus via subscription
        /// ChatWidget always reads latest messages via computed property

        // Sync shared data settings into UI state
        useSharedData = conversation.settings.useSharedData
        assignedSharedTopicId = conversation.settings.sharedTopicId?.uuidString

        // Sync panel visibility states from conversation settings
        showingMemoryPanel = conversation.settings.showingMemoryPanel
        showingTerminalPanel = conversation.settings.showingTerminalPanel
        showingWorkingDirectoryPanel = conversation.settings.showingWorkingDirectoryPanel
        showAdvancedParameters = conversation.settings.showAdvancedParameters
        showingPerformanceMetrics = conversation.settings.showingPerformanceMetrics

        logger.debug("PANEL_SYNC: Loaded panel states - memory:\(showingMemoryPanel) terminal:\(showingTerminalPanel) workdir:\(showingWorkingDirectoryPanel) advanced:\(showAdvancedParameters) perf:\(showingPerformanceMetrics)")

        /// Sync settings from conversation with validation to prevent crashes.
        selectedModel = conversation.settings.selectedModel

        /// Validate temperature (must be 0.0...2.0, not NaN/Inf).
        let loadedTemp = conversation.settings.temperature
        temperature = (loadedTemp.isNaN || loadedTemp.isInfinite || loadedTemp < 0.0 || loadedTemp > 2.0) ? 0.7 : loadedTemp

        /// Validate topP (must be 0.0...1.0, not NaN/Inf).
        let loadedTopP = conversation.settings.topP
        topP = (loadedTopP.isNaN || loadedTopP.isInfinite || loadedTopP < 0.0 || loadedTopP > 1.0) ? 1.0 : loadedTopP

        /// Validate maxTokens - treat nil, 0, or values below 1024 as "use default" (nil)
        /// This prevents broken responses when maxTokens is erroneously set to 0 or very low values
        let loadedMaxTokens = conversation.settings.maxTokens
        if let tokens = loadedMaxTokens, tokens >= 1024 {
            maxTokens = tokens
        } else {
            maxTokens = nil  // Will use model default or 8192
        }
        contextWindowSize = conversation.settings.contextWindowSize
        enableReasoning = conversation.settings.enableReasoning
        enableTools = conversation.settings.enableTools
        autoApprove = conversation.settings.autoApprove
        enableTerminalAccess = conversation.settings.enableTerminalAccess
        enableWorkflowMode = conversation.settings.enableWorkflowMode
        enableDynamicIterations = conversation.settings.enableDynamicIterations
        /// scrollLockEnabled is now global (@AppStorage), not per-conversation

        /// Sync Stable Diffusion settings from conversation
        sdSteps = conversation.settings.sdSteps
        sdGuidanceScale = conversation.settings.sdGuidanceScale
        sdScheduler = conversation.settings.sdScheduler
        sdNegativePrompt = conversation.settings.sdNegativePrompt
        sdSeed = conversation.settings.sdSeed
        sdUseKarras = conversation.settings.sdUseKarras
        sdImageCount = conversation.settings.sdImageCount
        sdImageWidth = conversation.settings.sdImageWidth
        sdImageHeight = conversation.settings.sdImageHeight
        sdEngine = conversation.settings.sdEngine
        sdDevice = conversation.settings.sdDevice
        sdUpscaleModel = conversation.settings.sdUpscaleModel
        sdStrength = conversation.settings.sdStrength
        sdInputImagePath = conversation.settings.sdInputImagePath

        /// Z-Image models now work on MPS with bfloat16 (2x faster than CPU)
        /// No automatic device switching needed on restore
        if isZImageModel {
            logger.info("Z-Image model restored - MPS with bfloat16 is now supported")
        }

        /// Auto-adjust guidance scale for Z-Image models if out of range
        if isZImageModel && sdGuidanceScale > guidanceScaleRange.upperBound {
            sdGuidanceScale = defaultGuidanceScale
            logger.info("Auto-adjusted restored guidance scale for Z-Image model: \\(sdGuidanceScale)")
        }

        /// Auto-validate image size for Z-Image models on restore
        if isZImageModel {
            let currentSize = "\\(sdImageWidth)×\\(sdImageHeight)"
            if !availableImageSizes.contains(currentSize) {
                if let firstSize = availableImageSizes.first {
                    let components = firstSize.split(separator: "×")
                    if components.count == 2,
                       let width = Int(components[0]),
                       let height = Int(components[1]) {
                        sdImageWidth = width
                        sdImageHeight = height
                        logger.info("Auto-adjusted restored image size for Z-Image model: \\(firstSize)")
                    }
                }
            }
        }

        /// Sync auto-approve state to AuthorizationManager.
        AuthorizationManager.shared.setAutoApprove(autoApprove, conversationId: conversation.id)

        /// Update max context window based on model (after loading selectedModel).
        updateMaxContextForModel()

        /// Pre-load the model to reduce first-message latency.
        preloadModel()

        /// CRITICAL: Restore processing state from StateManager (Task 18)
        /// Must happen AFTER syncing settings to avoid being overwritten
        if let state = conversationManager.stateManager.getState(conversationId: conversation.id) {
            logger.debug("SYNC_STATE_RESTORE: Found state in StateManager: \(state.status)")

            /// Restore processing status from state
            switch state.status {
            case .idle:
                isSending = false
                processingStatus = .idle
                logger.debug("SYNC_STATE_RESTORE: Restored idle state")
            case .processing(let toolName):
                isSending = true
                processingStatus = .generating
                logger.debug("SYNC_STATE_RESTORE: Restored processing state: \(toolName ?? "unknown tool")")
            case .streaming:
                isSending = true
                processingStatus = .generating
                logger.debug("SYNC_STATE_RESTORE: Restored streaming state")
            case .error(let msg):
                isSending = false
                processingStatus = .idle
                logger.debug("SYNC_STATE_RESTORE: Conversation has error state: \(msg)")
            }
        } else {
            logger.debug("SYNC_STATE_RESTORE: No state in StateManager, using fallback")
            /// No state in StateManager - use conversation.isProcessing as fallback
            isSending = conversation.isProcessing
            processingStatus = conversation.isProcessing ? .generating : .idle
        }

        /// Always sync system prompt - use conversation's if available, otherwise use shared state SystemPromptManager.init() ensures selectedConfigurationId is always set (to SAM Default or first config).
        if let conversationSystemPromptId = conversation.settings.selectedSystemPromptId {
            systemPromptManager.selectedConfigurationId = conversationSystemPromptId
        }
        /// else: keep existing systemPromptManager.selectedConfigurationId (already initialized to default).
    }

    /// REMOVED: syncMessagesToConversation() function
    /// ConversationModel.messages auto-syncs FROM MessageBus via subscription
    /// No manual sync needed - SwiftUI @Published handles reactivity
    ///
    /// Architecture:
    /// - MessageBus is the single source of truth for messages
    /// - ConversationModel subscribes to MessageBus.objectWillChange
    /// - When MessageBus changes, ConversationModel.messages updates automatically
    /// - ChatWidget reads from activeConversation.messages (computed property)
    /// - SwiftUI handles UI updates via @Published
    ///
    /// See ConversationModel.initializeMessageBus() (line ~590) for subscription setup
    /// See commits f682a847, 8943c473, 57b087e1 for implementation details

    private func updateMaxContextForModel() {
        /// Query model capabilities from EndpointManager.
        logger.debug("Querying model capabilities for: \(selectedModel)")

        Task {
            do {
                var maxTokens: Int?
                var isMLXModel = false
                var isLlamaModel = false

                /// CORRECT: Determine model type by checking which PROVIDER handles it NOT by checking filename patterns.
                if let providerType = endpointManager.getProviderTypeForModel(selectedModel) {
                    logger.debug("Provider type for \(selectedModel): \(providerType)")
                    isMLXModel = providerType.contains("MLXProvider")
                    isLlamaModel = providerType.contains("LlamaProvider")
                }

                /// For local models, try reading config files first.
                if isMLXModel || isLlamaModel {
                    /// Pass full model ID - the function will search all provider directories
                    maxTokens = await endpointManager.getLocalModelContextSize(modelName: selectedModel)
                    if let tokens = maxTokens {
                        logger.debug("Read local model context size from config: \(tokens/1000)k tokens")
                    }
                }

                /// If local read failed, try provider-specific APIs for remote models.
                if maxTokens == nil {
                    /// Check if this is a Gemini model (gemini/ prefix)
                    if selectedModel.hasPrefix("gemini/") {
                        if let capabilities = try await endpointManager.getGeminiModelCapabilities() {
                            let modelWithoutProvider = selectedModel.components(separatedBy: "/").last ?? selectedModel
                            if let apiTokens = capabilities[modelWithoutProvider] {
                                maxTokens = apiTokens
                                logger.debug("Read context size from Gemini API: \(apiTokens/1000)k tokens for \(modelWithoutProvider)")
                            } else {
                                logger.debug("Gemini model \(modelWithoutProvider) not found in API response")
                            }
                        } else {
                            logger.debug("Gemini API returned nil capabilities")
                        }
                    }
                    /// Try GitHub Copilot API for github_copilot/ models
                    else if selectedModel.hasPrefix("github_copilot/") {
                        if let capabilities = try await endpointManager.getGitHubCopilotModelCapabilities() {
                            logger.debug("GitHub Copilot API returned capabilities: \(capabilities.keys.joined(separator: ", "))")

                            /// Try exact match first.
                            if let apiTokens = capabilities[selectedModel] {
                                maxTokens = apiTokens
                                logger.debug("Read context size from API (exact match): \(apiTokens/1000)k tokens")
                            } else {
                                /// Try without provider prefix (github_copilot/gpt-4 → gpt-4).
                                let modelWithoutProvider = selectedModel.components(separatedBy: "/").last ?? selectedModel
                                if let apiTokens = capabilities[modelWithoutProvider] {
                                    maxTokens = apiTokens
                                    logger.debug("Read context size from API (stripped prefix): \(apiTokens/1000)k tokens for \(modelWithoutProvider)")
                                } else {
                                    logger.warning("Model \(selectedModel) not found in GitHub Copilot capabilities (tried '\(selectedModel)' and '\(modelWithoutProvider)')")
                                }
                            }
                        } else {
                            logger.debug("GitHub Copilot API returned nil capabilities")
                        }
                    }
                }
                
                /// If still not found via provider APIs, try model_config.json as fallback.
                if maxTokens == nil {
                    let modelWithoutProvider = selectedModel.components(separatedBy: "/").last ?? selectedModel
                    if let contextWindow = ModelConfigurationManager.shared.getContextWindow(for: modelWithoutProvider) {
                        maxTokens = contextWindow
                        logger.debug("Read context size from model_config.json (fallback): \(contextWindow/1000)k tokens for \(modelWithoutProvider)")
                    }
                }

                /// Apply the discovered max context size.
                if let tokens = maxTokens {
                    await MainActor.run {
                        let oldMax = maxContextWindowSize

                        /// Apply optimization preset for local models, but use DISCOVERED context size as the max.
                        if isMLXModel || isLlamaModel {
                            /// Determine which optimization to apply based on actual provider type.
                            if isMLXModel {
                                let mlxConfig = getGlobalMLXConfiguration()

                                /// Use DISCOVERED context size as the max, not the RAM-based preset
                                /// Max tokens = 50% of context, capped at 16k, minimum 2048
                                let effectiveMaxContext = tokens
                                let effectiveMaxTokens = max(2048, min(tokens / 2, 16384))

                                maxContextWindowSize = effectiveMaxContext
                                maxMaxTokens = effectiveMaxTokens

                                /// When model context is KNOWN, set current values to MAX
                                /// User can reduce via sliders if needed
                                contextWindowSize = effectiveMaxContext
                                self.maxTokens = effectiveMaxTokens
                                self.topP = mlxConfig.topP
                                self.temperature = mlxConfig.temperature

                                /// Auto-disable tools for models with <16k context (SAM prompts are large)
                                if effectiveMaxContext < 16384 && enableTools {
                                    enableTools = false
                                    logger.info("AUTO_DISABLE_TOOLS: Disabled tools for MLX model with \(effectiveMaxContext) context (requires 16k+ for tool support)")
                                }

                                logger.debug("Applied MLX optimization (model context known): modelContext=\(effectiveMaxContext), maxMaxTokens=\(effectiveMaxTokens), currentContext=\(contextWindowSize), currentMaxTokens=\(self.maxTokens ?? 0), topP=\(mlxConfig.topP), temp=\(mlxConfig.temperature)")
                            } else if isLlamaModel {
                                let llamaConfig = getGlobalLlamaConfiguration()

                                /// Use DISCOVERED context size as the max, not the RAM-based preset
                                /// Max tokens = 50% of context, capped at 16k, minimum 2048
                                let effectiveMaxContext = tokens
                                let effectiveMaxTokens = max(2048, min(tokens / 2, 16384))

                                maxContextWindowSize = effectiveMaxContext
                                maxMaxTokens = effectiveMaxTokens

                                /// When model context is KNOWN, set current values to MAX
                                /// User can reduce via sliders if needed
                                contextWindowSize = effectiveMaxContext
                                self.maxTokens = effectiveMaxTokens
                                self.topP = llamaConfig.topP
                                self.temperature = llamaConfig.temperature

                                /// Auto-disable tools for models with <16k context (SAM prompts are large)
                                if effectiveMaxContext < 16384 && enableTools {
                                    enableTools = false
                                    logger.info("AUTO_DISABLE_TOOLS: Disabled tools for llama.cpp model with \(effectiveMaxContext) context (requires 16k+ for tool support)")
                                }

                                logger.debug("Applied llama.cpp optimization (model context known): modelContext=\(effectiveMaxContext), maxMaxTokens=\(effectiveMaxTokens), currentContext=\(contextWindowSize), currentMaxTokens=\(self.maxTokens ?? 0), topP=\(llamaConfig.topP), temp=\(llamaConfig.temperature)")
                            }

                            /// Sync updated settings to conversation AFTER applying preset.
                            syncSettingsToConversation()
                        } else {
                            /// Remote model - use discovered capabilities.
                            maxContextWindowSize = tokens
                            logger.debug("Set maxContextWindowSize to \(tokens/1000)k from model metadata for \(selectedModel)")

                            /// Also set maxMaxTokens based on model context Max output should be reasonable fraction of context (50% is typical).
                            maxMaxTokens = min(tokens / 2, 16384)
                            logger.debug("Set maxMaxTokens to \(maxMaxTokens/1000)k (50% of context, capped at 16k)")

                            /// When switching models, if slider was at old model's max, move to new max This ensures users get full capacity when upgrading to larger context models If user manually reduced slider below max, preserve their choice.
                            if contextWindowSize == oldMax || contextWindowSize == ConversationSettings().contextWindowSize {
                                /// Slider was at previous max OR still at default → update to new max.
                                contextWindowSize = tokens
                                logger.debug("Setting context to model's maximum: \(tokens/1000)k tokens (user can reduce via slider)")
                            } else if contextWindowSize > maxContextWindowSize {
                                /// Clamp if user's value exceeds new model's max.
                                contextWindowSize = maxContextWindowSize
                                logger.debug("Clamping context to new model's max: \(maxContextWindowSize/1000)k tokens")
                            } else {
                                /// User manually set slider below old max → preserve their choice.
                                logger.debug("Preserving user-configured context: \(contextWindowSize/1000)k tokens (max: \(maxContextWindowSize/1000)k)")
                            }

                            /// Similarly clamp maxTokens if needed.
                            if let currentMaxTokens = self.maxTokens, currentMaxTokens > maxMaxTokens {
                                self.maxTokens = maxMaxTokens
                                logger.debug("Clamping maxTokens to new model's max: \(maxMaxTokens/1000)k tokens")
                            }

                            /// Sync updated settings to conversation.
                            syncSettingsToConversation()
                        }
                    }
                } else {
                    /// Fallback: no context size found - use safe defaults.
                    await MainActor.run {
                        /// If it's a local model, use safe defaults when context is UNKNOWN
                        if isMLXModel || isLlamaModel {
                            /// Safe defaults: 4k context, 2k max tokens (user requested minimums)
                            let safeContextDefault = 4096
                            let safeMaxTokensDefault = 2048

                            if isMLXModel {
                                let mlxConfig = getGlobalMLXConfiguration()

                                /// Use safe defaults as both max AND current values
                                maxContextWindowSize = safeContextDefault
                                maxMaxTokens = safeMaxTokensDefault
                                contextWindowSize = safeContextDefault
                                self.maxTokens = safeMaxTokensDefault
                                self.topP = mlxConfig.topP
                                self.temperature = mlxConfig.temperature

                                /// Auto-disable tools for models with <16k context (SAM prompts are large)
                                enableTools = false
                                logger.info("AUTO_DISABLE_TOOLS: Disabled tools for MLX model with unknown context (using safe \(safeContextDefault) default)")

                                logger.debug("Model context UNKNOWN - Applied safe defaults: context=\(safeContextDefault), maxTokens=\(safeMaxTokensDefault), topP=\(mlxConfig.topP), temp=\(mlxConfig.temperature)")
                            } else if isLlamaModel {
                                let llamaConfig = getGlobalLlamaConfiguration()

                                /// Use safe defaults as both max AND current values
                                maxContextWindowSize = safeContextDefault
                                maxMaxTokens = safeMaxTokensDefault
                                contextWindowSize = safeContextDefault
                                self.maxTokens = safeMaxTokensDefault
                                self.topP = llamaConfig.topP
                                self.temperature = llamaConfig.temperature

                                /// Auto-disable tools for models with <16k context (SAM prompts are large)
                                enableTools = false
                                logger.info("AUTO_DISABLE_TOOLS: Disabled tools for llama.cpp model with unknown context (using safe \(safeContextDefault) default)")

                                logger.debug("Model context UNKNOWN - Applied safe defaults: context=\(safeContextDefault), maxTokens=\(safeMaxTokensDefault), topP=\(llamaConfig.topP), temp=\(llamaConfig.temperature)")
                            }

                            /// Sync updated settings to conversation AFTER applying preset.
                            syncSettingsToConversation()
                        } else {
                            /// Remote model fallback.
                            maxContextWindowSize = 32768
                            maxMaxTokens = 16384
                            logger.debug("No context size found for \(selectedModel), using default 32k context, 16k max tokens")
                            if contextWindowSize > maxContextWindowSize {
                                contextWindowSize = maxContextWindowSize
                            }
                            if let currentMaxTokens = self.maxTokens, currentMaxTokens > maxMaxTokens {
                                self.maxTokens = maxMaxTokens
                            }

                            /// Sync updated settings to conversation.
                            syncSettingsToConversation()
                        }
                    }
                }
            } catch {
                logger.warning("Failed to query model capabilities for \(selectedModel): \(error)")
                /// Fallback to default on error.
                await MainActor.run {
                    maxContextWindowSize = 32768
                    maxMaxTokens = 16384
                    if contextWindowSize > maxContextWindowSize {
                        contextWindowSize = maxContextWindowSize
                    }
                    if let currentMaxTokens = self.maxTokens, currentMaxTokens > maxMaxTokens {
                        self.maxTokens = maxMaxTokens
                    }

                    /// Sync updated settings to conversation.
                    syncSettingsToConversation()
                }
            }
        }
    }

    private func preloadModel() {
        logger.debug("Pre-loading model: \(selectedModel)")

        /// Check if a different local model is currently loaded and unload it first This prevents memory leaks from keeping multiple large models loaded simultaneously.
        let isLocalModel = selectedModel.lowercased().contains("mlx/") ||
                          selectedModel.lowercased().contains("gguf") ||
                          selectedModel.lowercased().contains("llama")

        logger.debug("PRELOAD_CHECK: isLocalModel=\(isLocalModel) for model: \(selectedModel)")

        /// Pre-load/pre-warm the selected model to reduce first-message latency Uses Task.detached with background priority to avoid blocking UI.

        /// Capture necessary values to avoid MainActor isolation issues.
        let model = selectedModel
        let manager = endpointManager

        Task.detached(priority: .background) {
            /// For local models, check if a different model is loaded and unload it first.
            if isLocalModel {
                /// Check what model is currently loaded.
                let currentlyLoadedModel = await manager.getActiveLocalModelIdentifier()
                logger.debug("PRELOAD_CHECK: Currently loaded: \(currentlyLoadedModel ?? "none"), Want to load: \(model)")

                /// Extract base model name for comparison (strip .gguf extension and path).
                let baseModelName = model.replacingOccurrences(of: ".gguf", with: "")
                                        .replacingOccurrences(of: "mlx/", with: "")
                                        .replacingOccurrences(of: "llama/", with: "")

                /// Check if same model is already loaded.
                if let currentModel = currentlyLoadedModel, currentModel.contains(baseModelName) {
                    logger.debug("PRELOAD_OPTIMIZATION: Model \(baseModelName) already loaded, skipping unload/reload")
                    return
                } else {
                    logger.debug("PRELOAD_UNLOAD: Unloading previous model (\(currentlyLoadedModel ?? "none")) before loading \(model)")
                    await manager.unloadAllLocalModels()
                    logger.debug("PRELOAD_UNLOAD: Unload complete, model will load on first user message")
                }
            }

            /// DECISION: Disable preload inference for now - GPU OOM issues during preload with system prompts - Unload (the critical fix) works without preload inference - Model loads on first user message (slight delay but safe) - Can re-enable later after investigating GPU memory limits.
            logger.debug("PRELOAD: Model unloaded successfully, will load on first user message")
        }
    }

    private func syncSettingsToConversation() {
        guard let conversation = activeConversation else { return }

        /// Update conversation settings from UI state.
        conversation.settings.selectedModel = selectedModel
        conversation.settings.temperature = temperature
        conversation.settings.topP = topP
        conversation.settings.maxTokens = maxTokens
        conversation.settings.contextWindowSize = contextWindowSize
        /// NOTE: Don't override selectedSystemPromptId here - it's managed by prompt picker binding
        /// and auto-select logic in onChange(of: selectedModel)
        conversation.settings.enableReasoning = enableReasoning
        conversation.settings.enableTools = enableTools
        conversation.settings.autoApprove = autoApprove
        conversation.settings.enableTerminalAccess = enableTerminalAccess
        conversation.settings.enableWorkflowMode = enableWorkflowMode
        conversation.settings.enableDynamicIterations = enableDynamicIterations
        /// scrollLockEnabled is now global (@AppStorage), not per-conversation
        conversation.settings.useSharedData = useSharedData
        conversation.settings.sharedTopicId = assignedSharedTopicId.flatMap { UUID(uuidString: $0) }
        conversation.settings.sharedTopicName = assignedSharedTopicId.flatMap { id in sharedTopics.first(where: { $0.id == id })?.name }

        /// Sync Stable Diffusion settings to conversation
        conversation.settings.sdSteps = sdSteps
        conversation.settings.sdGuidanceScale = sdGuidanceScale
        conversation.settings.sdScheduler = sdScheduler
        conversation.settings.sdNegativePrompt = sdNegativePrompt
        conversation.settings.sdSeed = sdSeed
        conversation.settings.sdUseKarras = sdUseKarras
        conversation.settings.sdImageCount = sdImageCount
        conversation.settings.sdImageWidth = sdImageWidth
        conversation.settings.sdImageHeight = sdImageHeight
        conversation.settings.sdEngine = sdEngine
        conversation.settings.sdDevice = sdDevice
        conversation.settings.sdUpscaleModel = sdUpscaleModel
        conversation.settings.sdStrength = sdStrength
        conversation.settings.sdInputImagePath = sdInputImagePath

        /// Sync panel visibility states to conversation
        conversation.settings.showingMemoryPanel = showingMemoryPanel
        conversation.settings.showingTerminalPanel = showingTerminalPanel
        conversation.settings.showingWorkingDirectoryPanel = showingWorkingDirectoryPanel
        conversation.settings.showAdvancedParameters = showAdvancedParameters
        conversation.settings.showingPerformanceMetrics = showingPerformanceMetrics

        conversation.updated = Date()

        /// Save conversations to disk after updating settings.
        conversationManager.saveConversations()
    }

    /// Save panel visibility state to conversation settings
    private func savePanelState(panel: String, value: Bool) {
        logger.debug("PANEL_CHANGE: \(panel) panel changed to \(value), isLoading=\(isLoadingConversationSettings), hasConv=\(activeConversation != nil)")

        guard let conversation = activeConversation, !isLoadingConversationSettings else {
            logger.debug("PANEL_BLOCKED: \(panel) panel save blocked - isLoading=\(isLoadingConversationSettings), hasConv=\(activeConversation != nil)")
            return
        }

        switch panel {
        case "memory":
            conversation.settings.showingMemoryPanel = value
        case "terminal":
            conversation.settings.showingTerminalPanel = value
        case "workdir":
            conversation.settings.showingWorkingDirectoryPanel = value
        case "advanced":
            conversation.settings.showAdvancedParameters = value
        case "perf":
            conversation.settings.showingPerformanceMetrics = value
        default:
            logger.error("Unknown panel: \(panel)")
            return
        }

        conversationManager.saveConversations()
        logger.debug("PANEL_SAVE: \(panel) panel = \(value)")
    }

    // MARK: - Local Model Loading

    /// Load a local model into memory and update UI parameters.
    private func loadLocalModel() {
        guard endpointManager.isLocalModel(selectedModel) else { return }

        /// Extract provider and model name from selectedModel (format: "provider/modelName").
        let components = selectedModel.components(separatedBy: "/")
        guard components.count >= 2 else {
            logger.error("CHATWIDGET: Invalid model format: \(selectedModel)")
            return
        }

        let provider = components[0]
        let modelName = components[1..<components.count].joined(separator: "/")

        /// Check memory requirements before loading.
        if let requirement = localModelManager.checkModelMemory(
            provider: provider,
            modelName: modelName,
            inferenceLimitGB: 8.0
        ) {
            if !requirement.isSafe {
                /// Show warning dialog.
                showMemoryWarning = true
                memoryWarningMessage = requirement.warningMessage ?? "This model may require more memory than available."
                pendingModelLoad = (provider: provider, model: modelName)
                return
            }
        }

        /// Safe to load (or couldn't determine requirements).
        performModelLoad()
    }

    /// Actually load the model (called after memory check passes or user overrides).
    private func performModelLoad() {
        guard endpointManager.isLocalModel(selectedModel) else { return }

        isLoadingLocalModel = true

        Task {
            do {
                logger.info("CHATWIDGET: Loading local model: \(selectedModel)")
                let capabilities = try await endpointManager.loadLocalModel(selectedModel)

                await MainActor.run {
                    /// Update parameters from model capabilities.
                    maxContextWindowSize = capabilities.contextSize
                    contextWindowSize = min(contextWindowSize, capabilities.contextSize)
                    maxMaxTokens = capabilities.maxTokens
                    if let currentMaxTokens = maxTokens {
                        maxTokens = min(currentMaxTokens, capabilities.maxTokens)
                    } else {
                        maxTokens = capabilities.maxTokens
                    }

                    isLocalModelLoaded = true
                    isLoadingLocalModel = false

                    logger.debug("CHATWIDGET: Model loaded - context: \(capabilities.contextSize), max_tokens: \(capabilities.maxTokens)")
                }
            } catch {
                await MainActor.run {
                    isLoadingLocalModel = false
                    isLocalModelLoaded = false
                    logger.error("CHATWIDGET: Failed to load model: \(error)")
                    /// Error is logged - UI shows loading state changes.
                }
            }
        }
    }

    /// Eject (unload) a local model from memory.
    private func ejectLocalModel() {
        guard endpointManager.isLocalModel(selectedModel) else { return }

        Task {
            logger.info("CHATWIDGET: Ejecting local model: \(selectedModel)")
            await endpointManager.ejectLocalModel(selectedModel)

            await MainActor.run {
                isLocalModelLoaded = false
                logger.info("CHATWIDGET: Model ejected")
            }
        }
    }

    private func sendMessage() {
        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isSending else { return }

        /// RACE CONDITION FIX: Wait if files are still being copied
        /// This prevents the agent from trying to import files before the copy completes
        if isAttachingFiles {
            logger.warning("Send blocked - waiting for file attachments to complete")
            /// Schedule retry after a brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
                self.sendMessage()
            }
            return
        }

        let originalText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        var textForAPI = originalText
        var injectedContexts: [String] = []

        /// FEATURE: Inject mini-prompts into user message for maximum AI attention (per-conversation).
        if let activeConversation = activeConversation {
            let miniPromptText = MiniPromptManager.shared.getInjectedText(
                for: activeConversation.id,
                enabledIds: activeConversation.enabledMiniPromptIds
            )
            if !miniPromptText.isEmpty {
                injectedContexts.append(miniPromptText)
                let enabledPrompts = MiniPromptManager.shared.enabledPrompts(
                    for: activeConversation.id,
                    enabledIds: activeConversation.enabledMiniPromptIds
                )
                logger.info("Injected \(enabledPrompts.count) mini-prompt(s) into user message: \(enabledPrompts.map { $0.name }.joined(separator: ", "))")
            }
        }

        /// FEATURE: Inject user location context if configured
        if let locationContext = LocationManager.shared.getLocationContext() {
            injectedContexts.append(locationContext)
            logger.debug("Injected location context into user message")
        }

        /// FEATURE: Auto-import attached files into conversation memory BEFORE sending user message
        /// This ensures agent knows files are already available when it receives the message
        if !attachedFiles.isEmpty {
            logger.info("Auto-importing \(attachedFiles.count) attached file(s) before sending message")
            
            /// Get active conversation for import
            guard let conversation = activeConversation else {
                logger.error("Cannot auto-import files - no active conversation")
                attachedFiles.removeAll()
                return
            }
            
            /// Ensure document import system is initialized
            guard let importSystem = documentImportSystem else {
                logger.error("Cannot auto-import files - DocumentImportSystem not initialized")
                attachedFiles.removeAll()
                return
            }
            
            /// Copy files list and message data before async operation
            let filesToImport = attachedFiles
            let savedOriginalText = originalText
            let savedInjectedContexts = injectedContexts
            
            /// Clear attached files array so we don't re-import
            attachedFiles.removeAll()
            
            /// IMMEDIATE FEEDBACK: Set busy state NOW
            /// This switches play button to stop immediately
            isSending = true
            conversation.isProcessing = true
            isActivelyStreaming = true
            processingStatus = .generating
            
            /// IMMEDIATE FEEDBACK: Create placeholder user message NOW
            /// This ensures user message appears before import tool cards
            let placeholderMessageId = messageBus.addUserMessage(
                content: savedOriginalText,  // Placeholder, will be replaced by processMessage
                isPinned: false
            )
            
            /// IMMEDIATE FEEDBACK: Create tool cards NOW (AFTER user message)
            var toolCardIds: [UUID] = []
            for fileURL in filesToImport {
                let filename = fileURL.lastPathComponent
                let toolMessageId = messageBus.addToolMessage(
                    name: "Document Import",
                    status: .queued,
                    details: "Queued: \(filename)",
                    category: "documents",
                    icon: "doc.text"
                )
                toolCardIds.append(toolMessageId)
            }
            logger.info("Created placeholder message + \(toolCardIds.count) tool cards for immediate feedback")
            
            /// Import files with tool card updates
            Task { @MainActor in
                var importedDocs: [(filename: String, id: String, size: Int)] = []
                
                for (index, fileURL) in filesToImport.enumerated() {
                    let filename = fileURL.lastPathComponent
                    let toolMessageId = toolCardIds[index]
                    
                    /// Update tool card to "running"
                    messageBus.updateToolStatus(
                        id: toolMessageId,
                        status: .running,
                        details: "Importing \(filename)..."
                    )
                    
                    do {
                        /// Import document into conversation memory
                        let document = try await importSystem.importDocument(
                            from: fileURL,
                            conversationId: conversation.id
                        )
                        
                        importedDocs.append((
                            filename: document.filename,
                            id: String(document.id.uuidString.prefix(8)),
                            size: document.content.count
                        ))
                        
                        /// Update tool card to "success"
                        messageBus.updateToolStatus(
                            id: toolMessageId,
                            status: .success,
                            details: "Imported \(document.filename) (\(document.content.count) chars)"
                        )
                        
                        logger.info("Auto-imported: \(document.filename) (\(document.content.count) chars)")
                    } catch {
                        /// Update tool card to "error"
                        messageBus.updateToolStatus(
                            id: toolMessageId,
                            status: .error,
                            details: "Failed to import \(filename): \(error.localizedDescription)"
                        )
                        logger.error("Failed to auto-import \(filename): \(error)")
                    }
                }
                
                /// Now that imports are complete, send the message with context
                var finalInjectedContexts = savedInjectedContexts
                
                if !importedDocs.isEmpty {
                    let docList = importedDocs.map { doc in
                        "\(doc.filename) (\(doc.size) chars, ID: \(doc.id))"
                    }.joined(separator: ", ")
                    
                    let attachedContext = """
                    ATTACHED FILES (PRE-IMPORTED): \(importedDocs.count) file(s) have been automatically imported into conversation memory.
                    Use memory_operations with operation=search_memory to query their content.
                    Files: \(docList)
                    """
                    
                    finalInjectedContexts.append(attachedContext)
                    logger.info("Pre-imported \(importedDocs.count) documents - adding context to message")
                }
                
                /// Build final message with all injected contexts
                var finalTextForAPI = savedOriginalText
                if !finalInjectedContexts.isEmpty {
                    finalTextForAPI += "\n\n<userContext>\n\(finalInjectedContexts.joined(separator: "\n"))\n</userContext>"
                }
                
                logger.info("Import complete, removing placeholder and sending final message with context")
                
                /// Remove the placeholder user message
                /// processMessage will add the real one with full context
                messageBus.removeMessage(id: placeholderMessageId)
                
                /// Clear message text in UI
                messageText = ""
                if let conv = activeConversation {
                    conv.settings.draftMessage = ""
                }
                
                /// Trigger conversation engine to process the message with import context
                /// This will add a new user message with full context and trigger the agent
                await processMessage(text: finalTextForAPI)
                
                /// Clean up after processing
                await MainActor.run {
                    isSending = false
                    isActivelyStreaming = false
                }
            }
            
            /// Return early - the Task will complete the send operation async
            return
        }

        /// Append all injected contexts to the API message
        /// VS CODE COPILOT PATTERN: Use XML tags for user context
        if !injectedContexts.isEmpty {
            textForAPI += "\n\n<userContext>\n\(injectedContexts.joined(separator: "\n"))\n</userContext>"
        }

        /// Only clear message text if NOT in Stable Diffusion mode (SD keeps prompt for refinement)
        if !isStableDiffusionOnlyMode {
            messageText = ""
            /// Clear draft when message is sent
            if let conversation = activeConversation {
                conversation.settings.draftMessage = ""
            }
        } else {
            /// In SD mode, save the prompt as draft so it persists across restarts
            /// (The prompt is kept in the UI for refinement, and should also persist to disk)
            if let conversation = activeConversation {
                conversation.settings.draftMessage = messageText
            }
        }

        /// Prevent multiple sends.
        isSending = true

        /// FEATURE: Direct Stable Diffusion mode - route to image generation
        if isStableDiffusionOnlyMode {
            streamingTask = Task {
                await generateImageDirectly(prompt: originalText)
                await MainActor.run {
                    isSending = false
                    streamingTask = nil
                }
            }
            return
        }

        /// Sync with conversation-level state for persistence across conversation switches
        if let conversation = activeConversation {
            conversation.isProcessing = true

            /// Update StateManager (Task 18): Track processing state
            conversationManager.stateManager.updateState(conversationId: conversation.id) { state in
                state.status = .processing(toolName: nil)
            }
            logger.debug("Updated StateManager: conversation \(conversation.id) now processing")
        }

        /// REMOVED: Don't force-enable scroll lock when user sends message
        /// User's scroll lock preference should be respected
        /// scrollLockEnabled = true  // OLD CODE - was overriding user preference

        /// CRITICAL: Mark streaming as active to prevent conversation sync
        /// This ensures UI messages (created from chunks) are not overwritten
        /// by stale data loaded from conversation file during streaming
        isActivelyStreaming = true
        logger.error("STREAMING_START: Setting isActivelyStreaming=true")

        /// Store the streaming task so it can be cancelled.
        streamingTask = Task {
            /// Message stored WITH context for API, filtered in UI display.
            await processMessage(text: textForAPI)
            await MainActor.run {
                isSending = false
                streamingTask = nil
                currentOrchestrator = nil

                /// Sync with conversation-level state
                if let conversation = activeConversation {
                    conversation.isProcessing = false

                    /// Update StateManager (Task 18): Mark as idle
                    conversationManager.stateManager.updateState(conversationId: conversation.id) { state in
                        state.status = .idle
                        state.activeTools.removeAll()
                    }
                    logger.debug("Updated StateManager: conversation \(conversation.id) now idle")
                }

                /// Trigger final scroll after completion to ensure last message is visible
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                }

                /// FEATURE: Play completion sound if enabled in preferences.
                /// Skip completion sound if speaking mode is enabled (agent is already speaking)
                if !voiceManager.speakingMode {
                    playCompletionSound()
                }
            }
        }
    }

    // MARK: - User Collaboration

    /// Submit user response to collaboration tool.
    private func submitUserResponse() {
        guard let toolCallId = userCollaborationToolCallId,
              let conversationId = activeConversation?.id else {
            logger.error("Cannot submit user response - missing toolCallId or conversationId")
            return
        }

        let userInput = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userInput.isEmpty else { return }

        logger.info("USER_COLLAB: Submitting user response for collaboration tool call: \(toolCallId)")

        /// Clear message text and reset collaboration state immediately
        /// The user's response will appear via streaming from AgentOrchestrator
        messageText = ""
        isAwaitingUserInput = false
        userCollaborationPrompt = ""
        userCollaborationContext = nil
        userCollaborationToolCallId = nil

        /// Submit response to API endpoint
        /// API will add to MessageBus and AgentOrchestrator will emit as streaming chunk
        Task {
            do {
                let url = URL(string: "http://127.0.0.1:8080/api/chat/tool-response")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                let requestBody: [String: String] = [
                    "conversationId": conversationId.uuidString,
                    "toolCallId": toolCallId,
                    "userInput": userInput
                ]

                request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

                let (_, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    logger.error("USER_COLLAB: Failed to submit user response - HTTP error")
                    return
                }

                logger.debug("User response submitted successfully")
                /// Streaming will automatically resume after tool unblocks.
            } catch {
                logger.error("Failed to submit user response: \(error)")
            }
        }
    }

    /// Parse SSE event from streaming chunk Handles three event types: - [SAM_EVENT:user_input_required] - Requests user input during tool execution - [SAM_EVENT:agent_status_update] - Shows agent workflow status (CONTINUE, WORK_COMPLETE) - [SAM_EVENT:image_display] - Displays generated images in chat.
    private func parseSSEEvent(from content: String) -> Bool {
        /// Check for image_display event first.
        if content.contains("[SAM_EVENT:image_display]") {
            let pattern = "\\[SAM_EVENT:image_display\\](.+)"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
                  let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
                  let jsonRange = Range(match.range(at: 1), in: content) else {
                return false
            }

            let jsonString = String(content[jsonRange])

            /// Parse JSON.
            guard let jsonData = jsonString.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let imagePaths = event["imagePaths"] as? [String],
                  let prompt = event["prompt"] as? String else {
                logger.error("Failed to parse image_display event")
                return false
            }

            /// Create message with contentParts for image display.
            DispatchQueue.main.async {
                /// Create contentParts from image paths.
                let contentParts = imagePaths.map { path in
                    MessageContentPart.imageUrl(ImageURL(url: "file://\(path)"))
                }

                /// Create assistant message with image content via MessageBus
                self.activeConversation?.messageBus?.addAssistantMessage(
                    content: prompt,
                    contentParts: contentParts,
                    isStreaming: false
                )

                self.logger.info("IMAGE_DISPLAY: Added image message with \(imagePaths.count) image(s) to chat via MessageBus")
            }

            return true
        }

        /// REMOVED: agent_status_update event handling
        /// This event is no longer emitted by AgentOrchestrator
        /// Status updates are now handled via:
        /// - Tool cards (ToolStatus updates via MessageBus)
        /// - MessageBus events (objectWillChange triggers UI updates)
        /// - No need for separate status messages

        /// Look for [SAM_EVENT:user_input_required]{JSON}.
        let pattern = "\\[SAM_EVENT:user_input_required\\](.+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let jsonRange = Range(match.range(at: 1), in: content) else {
            return false
        }

        let jsonString = String(content[jsonRange])

        /// Parse JSON.
        guard let jsonData = jsonString.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let toolCallId = event["toolCallId"] as? String,
              let prompt = event["prompt"] as? String else {
            logger.error("Failed to parse user_input_required event")
            return false
        }

        /// Update UI state to show collaboration prompt.
        DispatchQueue.main.async {
            /// Add agent's collaboration prompt as a visible message in the chat This ensures users see what the agent is asking in the conversation history.
            /// FEATURE: Pin collaboration prompts for context persistence
            let collaborationMessage = EnhancedMessage(
                id: UUID(),
                content: prompt,
                isFromUser: false,
                timestamp: Date(),
                processingTime: nil,
                performanceMetrics: nil,
                isToolMessage: false,
                isPinned: true,
                importance: 1.0
            )
            /// FIXED: Use MessageBus for collaboration prompt with pinning
            activeConversation?.messageBus?.addAssistantMessage(
                content: prompt,
                isStreaming: false,
                isPinned: true  // Collaboration prompts should be pinned for context
            )
            self.logger.debug("USER_COLLAB_UI: Added agent's collaboration prompt via MessageBus (pinned)")

            self.isAwaitingUserInput = true
            self.userCollaborationPrompt = prompt
            self.userCollaborationContext = event["context"] as? String
            self.userCollaborationToolCallId = toolCallId
            self.logger.debug("User collaboration requested: \(prompt)")

            /// FEATURE: Play attention sound if enabled in preferences.
            let enableSoundEffects = UserDefaults.standard.bool(forKey: "enableSoundEffects")
            let hasKey = UserDefaults.standard.object(forKey: "enableSoundEffects") != nil
            /// Default to true if never set (AppStorage default).
            let shouldPlaySound = hasKey ? enableSoundEffects : true

            if shouldPlaySound {
                /// Use system "Glass" sound for user attention This is a built-in macOS sound that's attention-grabbing but not jarring.
                if let sound = NSSound(named: "Glass") {
                    sound.play()
                    self.logger.debug("USER_COLLAB_SOUND: Played attention sound (Glass)")
                } else {
                    /// Fallback to default beep if Glass not available.
                    NSSound.beep()
                    self.logger.debug("USER_COLLAB_SOUND: Played beep (Glass not found)")
                }
            } else {
                self.logger.debug("USER_COLLAB_SOUND: Sound disabled in preferences, skipping")
            }
        }

        return true
    }

    /// FEATURE: Play completion sound when AI finishes response Uses same preference as user collaboration sound.
    private func playCompletionSound() {
        let enableSoundEffects = UserDefaults.standard.bool(forKey: "enableSoundEffects")
        let hasKey = UserDefaults.standard.object(forKey: "enableSoundEffects") != nil
        /// Default to true if never set (AppStorage default).
        let shouldPlaySound = hasKey ? enableSoundEffects : true

        if shouldPlaySound {
            /// Get configured notification sound from preferences (default: Submarine)
            let notificationSound = UserDefaults.standard.string(forKey: "notificationSound") ?? "Submarine"

            if let sound = NSSound(named: notificationSound) {
                sound.play()
                logger.debug("COMPLETION_SOUND: Played completion sound (\(notificationSound))")
            } else {
                /// Fallback to "Glass" sound.
                if let sound = NSSound(named: "Glass") {
                    sound.play()
                    logger.debug("COMPLETION_SOUND: Played completion sound (Glass fallback)")
                } else {
                    /// Final fallback to beep.
                    NSSound.beep()
                    logger.debug("COMPLETION_SOUND: Played beep (sounds not found)")
                }
            }
        } else {
            logger.debug("COMPLETION_SOUND: Sound disabled in preferences, skipping")
        }
    }

    /// Setup voice manager callbacks via bridge
    private func setupVoiceCallbacks() {
        /// Handle transcription updates
        voiceManager.onTranscriptionUpdate = { [weak voiceBridge] text in
            logger.debug("onTranscriptionUpdate called with: '\\(text)'")
            Task { @MainActor in
                logger.debug("Setting voiceBridge.transcribedText to: '\\(text)'")
                voiceBridge?.transcribedText = text
            }
        }

        /// Handle message ready to send
        voiceManager.onMessageReadyToSend = { [weak voiceBridge] in
            Task { @MainActor in
                voiceBridge?.shouldSendMessage = true
            }
        }

        /// Handle message cancelled
        voiceManager.onMessageCancelled = { [weak voiceBridge] in
            Task { @MainActor in
                voiceBridge?.shouldClearMessage = true
            }
        }

        /// Provide current message text getter
        voiceManager.getCurrentMessageText = { [weak voiceBridge] in
            return voiceBridge?.currentMessageText ?? ""
        }

        /// Handle authorization errors
        voiceManager.onAuthorizationError = { message in
            Task { @MainActor in
                voiceAuthErrorMessage = message
                showVoiceAuthError = true
            }
        }
    }

    /// Complete all running tool executions when workflow finishes This ensures tool cards transition to "Complete" state instead of staying in "Running".
    private func completeAllRunningTools() {
        var updatedCount = 0

        /// Update all running tool messages to success status via MessageBus
        for message in messages {
            /// Only update tool messages that are still in running state
            if message.toolStatus == .running {
                activeConversation?.messageBus?.updateMessage(
                    id: message.id,
                    status: .success
                )
                updatedCount += 1
            }
        }

        if updatedCount > 0 {
            logger.debug("TOOL_STATUS_UPDATE: Completed \(updatedCount) running tool(s) after workflow finish")
        }
    }

    /// PERFORMANCE OPTIMIZATION: Throttled UI updates for streaming Batches rapid streaming updates to reduce SwiftUI redraw overhead Target: ~60fps (16ms) or better, with logging for performance analysis.
    private func updateStreamingMessage(messageId: UUID, content: String) async {
        /// Store pending update.
        await MainActor.run {
            pendingStreamingUpdate = (messageId, content)
            streamingUpdateCount += 1
        }

        /// Cancel existing update task if running.
        streamingUpdateTask?.cancel()

        /// Create throttled update task.
        streamingUpdateTask = Task {
            /// Throttle: Wait 16ms (60fps) between UI updates This dramatically reduces SwiftUI overhead while maintaining smooth UX.
            try? await Task.sleep(nanoseconds: 16_000_000)

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let (id, text) = pendingStreamingUpdate else { return }

                /// Strip internal markers from streaming content BEFORE displaying Use a no-trim strategy: remove only lines that are EXACT markers (e.g.
                var cleanedText = filterInternalMarkersNoTrim(from: text)

                /// FIXED: Use MessageBus for streaming updates
                /// MessageBus.updateMessage() handles content updates and triggers ConversationModel sync
                activeConversation?.messageBus?.updateMessage(id: id, content: cleanedText)

                /// Performance tracking (no logging)
                if streamingUpdateCount % 50 == 0 {
                    lastUIUpdateTime = Date()
                }

                pendingStreamingUpdate = nil
            }
        }
    }

    /// Auto-select engine based on available formats
    private func autoSelectEngine() {
        guard let modelInfo = currentSDModelInfo else {
            logger.warning("autoSelectEngine: currentSDModelInfo is nil for selectedModel=\(selectedModel)")
            return
        }

        if !modelInfo.hasCoreML && modelInfo.hasSafeTensors {
            /// Only SafeTensors available - force Python
            sdEngine = "python"
            logger.info("autoSelectEngine: Selected Python (SafeTensors only)")
        } else if modelInfo.hasCoreML && !modelInfo.hasSafeTensors {
            /// Only CoreML available - force CoreML
            sdEngine = "coreml"
            logger.info("autoSelectEngine: Selected CoreML (CoreML only)")
        }
        /// If both available, keep user's selection
    }

    /// Direct Stable Diffusion generation (bypasses LLM)
    private func generateImageDirectly(prompt: String) async {
        logger.info("Direct SD generation started: \(prompt)")

        /// Extract SD model ID from selected model (format: "sd/model-id")
        let sdModelId = selectedModel.replacingOccurrences(of: "sd/", with: "")

        /// Add user message with auto-pinning and importance
        let currentUserMessageCount = messages.filter { $0.isFromUser }.count
        let shouldPin = currentUserMessageCount < 3  /// Auto-pin first 3 user messages
        let importance = calculateMessageImportance(text: prompt, isUser: true)

        let userMessage = EnhancedMessage(
            id: UUID(),
            content: prompt,
            isFromUser: true,
            timestamp: Date(),
            processingTime: nil,
            isPinned: shouldPin,
            importance: importance
        )

        await MainActor.run {
            /// REMOVED: messages.append(userMessage) - use MessageBus
            /// Messages are read-only computed property
            activeConversation?.messageBus?.addUserMessage(content: prompt)
            processingStatus = .generating
        }

        /// Get SD settings from conversation settings
        struct SDSettings {
            var steps: Int
            var guidanceScale: Int
            var scheduler: String
            var negativePrompt: String
            var seed: Int
            var useKarras: Bool
            var imageCount: Int
            var engine: String
            var device: String
            var upscaleModel: String
            var inputImagePath: String?
            var strength: Double
            var width: Int
            var height: Int

            /// Derived property: enable upscaling if model is not "none"
            var enableUpscaling: Bool {
                return upscaleModel != "none"
            }

            /// Derived property: img2img mode if input image provided
            var isImg2Img: Bool {
                return inputImagePath != nil
            }
        }

        /// Z-Image models now work on MPS with bfloat16 (2x faster than CPU)
        /// Python script auto-detects bfloat16 support and uses optimal dtype
        let requestedDevice = activeConversation?.settings.sdDevice ?? "auto"
        let effectiveDevice = requestedDevice
        if isZImageModel {
            logger.info("Z-Image direct generation - MPS with bfloat16 is now supported")
        }

        let settings = SDSettings(
            steps: activeConversation?.settings.sdSteps ?? 25,
            guidanceScale: activeConversation?.settings.sdGuidanceScale ?? 8,
            scheduler: activeConversation?.settings.sdScheduler ?? "dpm++",
            negativePrompt: activeConversation?.settings.sdNegativePrompt ?? "",
            seed: activeConversation?.settings.sdSeed ?? -1,
            useKarras: activeConversation?.settings.sdUseKarras ?? true,
            imageCount: activeConversation?.settings.sdImageCount ?? 1,
            engine: activeConversation?.settings.sdEngine ?? "coreml",
            device: effectiveDevice,
            upscaleModel: activeConversation?.settings.sdUpscaleModel ?? "none",
            inputImagePath: activeConversation?.settings.sdInputImagePath,
            strength: activeConversation?.settings.sdStrength ?? 0.75,
            width: activeConversation?.settings.sdImageWidth ?? 512,
            height: activeConversation?.settings.sdImageHeight ?? 512
        )

        /// Create SD service instances (reuse across all images)
        let sdService = StableDiffusionService()
        let pythonService = PythonDiffusersService()
        let upscalingService = UpscalingService()
        let orchestrator = StableDiffusionOrchestrator(
            coreMLService: sdService,
            pythonService: pythonService,
            upscalingService: upscalingService
        )
        let loraManager = LoRAManager()
        let imageTool = ImageGenerationTool(orchestrator: orchestrator, modelManager: sdModelManager, loraManager: loraManager)

        /// Create execution context (minimal for direct generation)
        let context = MCPExecutionContext(
            conversationId: activeConversation?.id ?? UUID(),
            workingDirectory: activeConversation?.workingDirectory
        )

        /// Generate multiple images in sequence
        let totalStartTime = Date()
        for imageIndex in 1...settings.imageCount {
            /// Check for cancellation between images
            if Task.isCancelled {
                await MainActor.run {
                    processingStatus = .idle
                    logger.info("Direct SD generation cancelled after \(imageIndex - 1) image(s)")
                }
                return
            }

            /// Create placeholder assistant message for this image
            let assistantId = UUID()
            let placeholderContent = settings.imageCount > 1
                ? "Generating image \(imageIndex)/\(settings.imageCount)..."
                : "Generating image..."

            let placeholderMessage = EnhancedMessage(
                id: assistantId,
                content: placeholderContent,
                isFromUser: false,
                timestamp: Date(),
                processingTime: nil,
                isToolMessage: false
            )

            await MainActor.run {
                /// REMOVED: messages.append(placeholderMessage) - use MessageBus
                /// Messages are read-only computed property
                /// Use addAssistantMessage(id:) to preserve the assistantId for later update
                activeConversation?.messageBus?.addAssistantMessage(
                    id: assistantId,
                    content: placeholderContent,
                    isStreaming: false
                )
            }

            /// Determine seed for this image
            /// If seed is -1 (random), each image gets a different random seed
            /// If seed is specified, increment for each image to get variations
            let imageSeed: Int
            if settings.seed == -1 {
                imageSeed = -1  /// Random seed for each image
            } else {
                imageSeed = settings.seed + (imageIndex - 1)  /// Incremented seed for variations
            }

            let parameters: [String: Any] = [
                "prompt": prompt,
                "model": sdModelId,
                "steps": settings.steps,
                "guidance_scale": settings.guidanceScale,
                "scheduler": settings.scheduler,
                "negative_prompt": settings.negativePrompt,
                "seed": imageSeed,
                "use_karras": settings.useKarras,
                "engine": settings.engine,
                "device": settings.device,
                "upscale": settings.enableUpscaling,
                "upscale_model": settings.upscaleModel,
                "input_image": settings.inputImagePath as Any,
                "strength": settings.strength,
                "width": settings.width,
                "height": settings.height
            ]

            let startTime = Date()
            let result = await imageTool.execute(parameters: parameters, context: context)
            let duration = Date().timeIntervalSince(startTime)

            /// Update assistant message with result
            await MainActor.run {
                if result.success {
                    /// Extract image paths from metadata and create contentParts
                    var contentParts: [MessageContentPart]?
                    if let imagePaths = result.metadata.additionalContext["imagePaths"],
                       !imagePaths.isEmpty {
                        let paths = imagePaths.split(separator: ",").map { String($0) }
                        contentParts = paths.map { path in
                            MessageContentPart.imageUrl(ImageURL(url: "file://\(path)"))
                        }
                        logger.info("DIRECT_SD: Created contentParts for \(paths.count) image(s)")
                    } else {
                        logger.warning("DIRECT_SD: No imagePaths in metadata! additionalContext keys: \(result.metadata.additionalContext.keys.joined(separator: ", "))")
                    }

                    /// For Direct SD: Just show the image, no text needed
                    let content = ""

                    /// Update existing message with image content via MessageBus
                    activeConversation?.messageBus?.updateMessage(
                        id: assistantId,
                        content: content,
                        contentParts: contentParts,
                        duration: duration
                    )

                    logger.info("DIRECT_SD: Updated message with image content via MessageBus")

                    logger.info("Direct SD image \(imageIndex)/\(settings.imageCount) completed in \(String(format: "%.2f", duration))s")
                } else {
                    updateMessageContent(messageId: assistantId, newContent: result.output.content, isComplete: true)
                    logger.error("Direct SD image \(imageIndex)/\(settings.imageCount) failed: \(result.output.content)")
                }
            }
        }

        /// All images complete
        let totalDuration = Date().timeIntervalSince(totalStartTime)
        await MainActor.run {
            processingStatus = .idle
            logger.info("Direct SD generation complete: \(settings.imageCount) image(s) in \(String(format: "%.2f", totalDuration))s")

            /// Play completion sound using configured notification sound
            let notificationSound = UserDefaults.standard.string(forKey: "notificationSound") ?? "Submarine"
            NSSound(named: notificationSound)?.play()
        }
    }

    private func processMessage(text: String) async {
        let processId = UUID().uuidString.prefix(8)
        logger.error("🟢 PROCESS_MESSAGE_START: processId=\(processId)")
        SAMLog.chatProcessMessage(text)
        let startTime = Date()

        /// Start performance tracking.
        let requestTokens = estimateTokenCount(for: text)
        let performanceTracker = await MainActor.run {
            performanceMonitor.startRequest(
                model: selectedModel,
                provider: "GitHub Copilot",
                requestTokens: requestTokens
            )
        }

        /// Auto-pinning logic for user messages
        let currentUserMessageCount = messages.filter { $0.isFromUser }.count
        let shouldPin = currentUserMessageCount < 3  /// Auto-pin first 3 user messages
        let importance = calculateMessageImportance(text: text, isUser: true)

        /// Add user message with performance tracking Store the FULL message (with mini-prompts) for API/memory, display filtered version in UI.
        let userMessage = EnhancedMessage(
            id: UUID(),
            content: text,
            isFromUser: true,
            timestamp: Date(),
            processingTime: nil,
            isPinned: shouldPin,
            importance: importance
        )

        await MainActor.run {
            /// FIXED: Use MessageBus for user message creation
            /// Messages now flow: MessageBus → ConversationModel → ChatWidget (computed property)
            activeConversation?.messageBus?.addUserMessage(content: text)
            /// Note: User message must exist before AgentOrchestrator runs (for getRecentMessages)
            processingStatus = .generating
        }

        /// ARCHITECTURE: Message creation happens in AgentOrchestrator, NOT ChatWidget
        /// ChatWidget is read-only observer of MessageBus
        ///
        /// Flow:
        /// 1. AgentOrchestrator creates message in MessageBus with UUID
        /// 2. AgentOrchestrator yields chunk with messageId field
        /// 3. ChatWidget reads chunk.messageId to track message
        /// 4. ChatWidget updates UI via MessageBus subscription (automatic)
        ///
        /// This prevents duplicate messages (one from ChatWidget, one from AgentOrchestrator)
        /// See: AgentOrchestrator.swift line 4705 (message creation)
        /// See: OpenAIModels.swift line 453 (messageId field documentation)

        /// Track the assistant message ID from first chunk
        var assistantMessageId: UUID?

        do {
            /// Build request using user configuration with system prompt.
            var openAIMessages: [OpenAIChatMessage] = []

            /// Add system prompt - RESTORED editable implementation.
            let systemPromptContent: String
            if let selectedId = systemPromptManager.selectedConfigurationId {
                systemPromptContent = systemPromptManager.generateSystemPrompt(for: selectedId, toolsEnabled: enableTools)
                logger.debug("Using selected system prompt: \(selectedId)")
            } else {
                /// Fallback to default generation (should not happen - init() sets default).
                systemPromptContent = systemPromptManager.generateSystemPrompt(toolsEnabled: enableTools)
                logger.debug("Using fallback system prompt generation")
            }

            logger.debug("System prompt content length: \(systemPromptContent.count)")
            if !systemPromptContent.isEmpty {
                openAIMessages.append(OpenAIChatMessage(role: "system", content: systemPromptContent))
                logger.debug("Added system message to request")
            }

            /// SAM 1.0 PARTIAL CONTEXT STRATEGY: Use memory system + recent messages instead of full history This matches SAM 1.0's sophisticated memory approach with intelligent context windowing.

            /// 1. ADAPTIVE CONTEXT WINDOW: Grow context with conversation length
            /// Short conversations: 8 messages (standard)
            /// Medium conversations: 16 messages (more context needed)
            /// Long conversations: 24 messages (complex multi-turn scenarios like D&D)
            /// This prevents middle context loss in long conversations
            let totalMessages = activeConversation?.messages.count ?? 0
            let contextWindowSize: Int = {
                if totalMessages < 10 {
                    return 8   // Short: standard window
                } else if totalMessages < 30 {
                    return 16  // Medium: expanded window
                } else {
                    return 24  // Long: large window for complex scenarios
                }
            }()
            let recentMessages = getRecentMessages(limit: contextWindowSize, excludingId: nil)  // No need to exclude - message not created yet

            /// 2.
            let memoryContext = await retrieveMemoryContext(query: text, conversationId: activeConversation?.id.uuidString)

            /// 3.
            let enhancedSystemPrompt = enhanceSystemPromptWithMemory(
                originalPrompt: systemPromptContent,
                memoryContext: memoryContext,
                recentMessages: recentMessages
            )

            /// 4.
            if let systemMessageIndex = openAIMessages.firstIndex(where: { $0.role == "system" }) {
                openAIMessages[systemMessageIndex] = OpenAIChatMessage(role: "system", content: enhancedSystemPrompt)
            } else if !enhancedSystemPrompt.isEmpty {
                openAIMessages.insert(OpenAIChatMessage(role: "system", content: enhancedSystemPrompt), at: 0)
            }

            /// 5.
            for message in recentMessages {
                let role = message.isFromUser ? "user" : "assistant"
                openAIMessages.append(OpenAIChatMessage(role: role, content: message.content))
            }

            /// 6. CRITICAL: Add current user message
            /// Recent messages might not include it yet due to async sync from MessageBus
            /// Explicitly add current user input to ensure it's in the request
            openAIMessages.append(OpenAIChatMessage(role: "user", content: text))

            logger.debug("PARTIAL_CONTEXT: Using \(recentMessages.count) recent messages + memory context (vs full history)")
            logger.debug("PARTIAL_CONTEXT: Enhanced system prompt length: \(enhancedSystemPrompt.count) chars")

            var requestData: [String: Any] = [
                "model": selectedModel,
                "messages": openAIMessages.map { ["role": $0.role, "content": $0.content] },
                "temperature": temperature,
                "top_p": topP,
                "stream": true
            ]

            /// Add max tokens if specified.
            if let maxTokensValue = maxTokens {
                requestData["max_tokens"] = maxTokensValue
            }

            /// Add repetition penalty if enabled (MLX-specific parameter).
            if let repPenalty = repetitionPenalty {
                requestData["repetition_penalty"] = repPenalty
            }

            let requestJSON = try JSONSerialization.data(withJSONObject: requestData)
            let openAIRequest = try JSONDecoder().decode(OpenAIChatRequest.self, from: requestJSON)

            /// Route UI through internal API server to ensure tool injection This ensures UI and API have identical behavior including MCP tool integration.
            SAMLog.chatStreamingStart(model: selectedModel, temperature: temperature)
            let streamingResponse = try await makeInternalAPIRequest(openAIRequest)
            var fullResponse = ""
            SAMLog.chatStreamingResponse()

            /// Process streaming response - incremental delta pattern STREAMING ARCHITECTURE: Incremental delta appending where delta.content contains only incremental text to append (not cumulative).
            var firstTokenReceived = false
            var currentMessageContent = ""

            /// STREAMING TTS: Accumulate text until we have a complete sentence, then queue it
            var sentenceAccumulator = ""
            let shouldSpeakStreaming = voiceManager.speakingMode

            for try await chunk in streamingResponse {
                /// CRITICAL: Update messageId when it changes (workflow iterations create new messages)
                /// Each workflow iteration creates its own assistant message with unique ID
                /// ChatWidget must track current message ID to append content to correct message
                if let msgId = chunk.messageId {
                    if assistantMessageId != msgId {
                        /// Message ID changed - new iteration/message started
                        if assistantMessageId != nil {
                            logger.debug("MESSAGE_ID_CHANGED: Switching from \(assistantMessageId!.uuidString.prefix(8)) to \(msgId.uuidString.prefix(8))")
                            /// Reset content accumulator for new message
                            currentMessageContent = ""
                        } else {
                            logger.debug("STREAMING_START: Captured messageId=\(msgId.uuidString.prefix(8)) from chunk")
                        }
                        assistantMessageId = msgId
                    }
                }

                /// Log chunk arrival time for debugging handshake timing with microsecond precision
                let ts = Date().timeIntervalSince1970
                let microseconds = Int(ts * 1_000_000)
                logger.error("TS:\(microseconds) CHUNK_ARRIVAL: processId=\(processId) chunkId=\(chunk.id)")

                /// Check if task was cancelled.
                if Task.isCancelled {
                    logger.debug("Streaming cancelled by user")
                    break
                }

                /// COLLABORATION USER MESSAGE: Handle user role chunks from collaboration responses
                if chunk.choices.first?.delta.role == "user",
                   let content = chunk.choices.first?.delta.content, !content.isEmpty {
                    logger.info("USER_COLLAB: Received user message chunk, adding to conversation", metadata: [
                        "content": .string(content)
                    ])

                    await MainActor.run {
                        /// FEATURE: Pin user collaboration responses for context persistence
                        /// Agents should remember what users answered to their questions
                        /// CRITICAL: Explicitly pin collaboration responses (override auto-pin logic)
                        /// Collaboration responses are ALWAYS critical context regardless of message count
                        activeConversation?.messageBus?.addUserMessage(content: content, isPinned: true)
                        logger.info("USER_COLLAB: User message added to chat (EXPLICITLY PINNED for context persistence)")
                    }
                    continue
                }

                // MARK: - first token for any assistant response
                if !firstTokenReceived && chunk.choices.first?.delta.role == "assistant" {
                    performanceTracker.markFirstToken()
                    firstTokenReceived = true
                }

                /// Check for finish_reason='stop' FIRST (before content check) AgentOrchestrator yields finish_reason='stop' with content: nil If we check content first, we skip the boundary marker entirely!.
                if let finishReason = chunk.choices.first?.finishReason, finishReason == "stop" {
                    /// Message finalization handled by AgentOrchestrator
                    /// ChatWidget just tracks local state for voice/final processing
                    if !currentMessageContent.isEmpty {
                        logger.debug("FINISH_STOP: Message complete, length=\(currentMessageContent.count)")
                        currentMessageContent = ""
                    }
                    continue
                }

                /// Process content chunks (if any).
                if let content = chunk.choices.first?.delta.content, !content.isEmpty {
                    SAMLog.chatDeltaReceived(content)

                    /// USER COLLABORATION: Check for [SAM_EVENT:user_input_required].
                    if parseSSEEvent(from: content) {
                        /// Event detected and UI state updated Streaming continues, tool is blocked waiting for user input.
                        continue
                    }

                    /// THINKING INDICATOR: Detect think tool execution Tool execution messages start with "SUCCESS: - " followed by action detail Think tool messages contain "hinking" (from "Thinking" or thought preview).
                    if content.contains("SUCCESS:") && content.lowercased().contains("hinking") {
                        await MainActor.run {
                            isThinking = true
                            processingStatus = .thinking
                        }
                    } else if content.contains("SUCCESS:") {
                        /// Extract tool name from content like "SUCCESS: - Using memory_search...".
                        let toolName = extractToolName(from: content) ?? "tool"
                        await MainActor.run {
                            isThinking = false
                            processingStatus = .processingTools(toolName: toolName)
                        }
                    } else if processingStatus != .generating {
                        /// Regular content generation - set to generating if not already.
                        await MainActor.run {
                            processingStatus = .generating
                        }
                    }

                    // MARK: - first token for performance tracking (backup for content-based detection)
                    if !firstTokenReceived {
                        performanceTracker.markFirstToken()
                        firstTokenReceived = true
                    }

                    /// CONVERSATIONAL STEP DETECTION: Check if this is a new conversation phase Tool messages are marked with isToolMessage flag from AgentOrchestrator.
                    let isToolMessage = chunk.isToolMessage == true
                    let currentToolName = chunk.toolName
                    let currentToolExecutionId = chunk.toolExecutionId

                    logger.error("CHUNK_RECEIVED: isToolMessage=\(isToolMessage) toolName=\(currentToolName ?? "nil") executionId=\(currentToolExecutionId ?? "nil") content=\(content.prefix(50)) chunkId=\(chunk.id)")

                    /// METADATA UPDATE: If chunk has metadata and matches current message executionId, update metadata
                    if let metadata = chunk.toolMetadata,
                       !metadata.isEmpty,
                       let execId = currentToolExecutionId,
                       execId == lastToolExecutionId,
                       let msgId = assistantMessageId {
                        await MainActor.run {
                            updateMessageMetadata(messageId: msgId, metadata: metadata, toolStatus: chunk.toolStatus)
                        }
                        logger.debug("METADATA_UPDATED: Applied metadata to message \(msgId): \(metadata)")
                    }

                    /// BUG FIX Detect tool boundaries by EXECUTION ID
                    /// Each tool execution should create a UNIQUE message/card
                    /// Previously: Only checked toolName → multiple calls to same tool shared card
                    /// Now: Check toolExecutionId for true uniqueness (web_search #1, #2, #3 each get unique cards)
                    let isNewConversationalStep: Bool
                    if isToolMessage {
                        /// For tool messages: Create new message when EXECUTION ID changes
                        /// This ensures each tool execution gets its own card, even same tool called multiple times
                        if let currentExecId = currentToolExecutionId, let lastExecId = lastToolExecutionId {
                            isNewConversationalStep = (currentExecId != lastExecId)
                        } else {
                            /// Fallback to toolName if no executionId (shouldn't happen, but defensive)
                            isNewConversationalStep = (lastToolName != currentToolName)
                        }
                    } else {
                        /// For regular content: Create new message when transitioning FROM tool to content.
                        isNewConversationalStep = lastToolProcessorMessage != isToolMessage
                    }

                    /// Track tool messages for proper message marking.
                    await MainActor.run {
                        lastToolProcessorMessage = isToolMessage
                        lastToolName = currentToolName
                        lastToolExecutionId = currentToolExecutionId
                    }

                    /// Create new message for new conversational steps (type transitions only).
                    if isNewConversationalStep && !currentMessageContent.isEmpty {
                        logger.error("MESSAGE_TRANSITION_DETECTED: tool=\(lastToolProcessorMessage) → tool=\(isToolMessage) currentId=\(assistantMessageId?.uuidString.prefix(8) ?? "nil")")
                        /// Message finalization handled by AgentOrchestrator
                        /// ChatWidget just resets local tracker
                        currentMessageContent = ""

                        logger.info("MESSAGE_TRANSITION: New message started due to type change (tool=\(lastToolProcessorMessage) → tool=\(isToolMessage))")
                    }

                    /// REMOVED: Message creation moved to AgentOrchestrator
                    /// Messages are now created in MessageBus before chunks are yielded
                    /// ChatWidget is read-only observer - NO message creation here
                    ///
                    /// Architecture Flow:
                    /// 1. AgentOrchestrator.callLLMStreaming creates message in MessageBus
                    /// 2. MessageBus publishes changes
                    /// 3. ConversationModel.messages syncs FROM MessageBus (auto)
                    /// 4. ChatWidget reads ConversationModel.messages (read-only)
                    /// 5. SwiftUI @Published triggers UI updates automatically
                    ///
                    /// See SESSION_HANDOFF_2025-11-27_0745.md for full details.
                    /// See commits f682a847, 8943c473, 57b087e1 for Part A implementation.

                    /// Skip content processing if we don't have messageId yet
                    guard let msgId = assistantMessageId else {
                        logger.warning("STREAMING_WARNING: Received content before messageId - chunk may be malformed")
                        continue
                    }

                    /// Track content for local accumulation (for voice/final processing ONLY)
                    /// DO NOT update MessageBus - AgentOrchestrator owns message updates
                    if currentMessageContent.isEmpty {
                        currentMessageContent = content
                    } else {
                        /// Append to local tracker for voice/final processing
                        if !content.isEmpty {
                            currentMessageContent += content
                            /// REMOVED: updateMessageContent - AgentOrchestrator handles via updateStreamingMessage
                            /// ChatWidget is observer only, tracks content locally for voice/completions
                        }
                    }

                    fullResponse += content
                    SAMLog.chatDeltaAppended(totalChars: fullResponse.count)

                    /// STREAMING TTS: Accumulate content and detect sentence boundaries
                    /// Queue complete sentences for immediate TTS while continuing to stream
                    if shouldSpeakStreaming && !isToolMessage {
                        sentenceAccumulator += content

                        /// Check for sentence-ending punctuation followed by space or end
                        /// Handles: "Hello. ", "Hello! ", "Hello? ", "Hello:\n"
                        let sentenceEnders = CharacterSet(charactersIn: ".!?:")
                        var remainingText = sentenceAccumulator

                        while let range = remainingText.rangeOfCharacter(from: sentenceEnders) {
                            let endIndex = range.upperBound

                            /// Check if we're at end of text or followed by whitespace/newline
                            let isAtEnd = endIndex == remainingText.endIndex
                            let hasFollowingWhitespace = !isAtEnd && remainingText[endIndex].isWhitespace

                            if isAtEnd || hasFollowingWhitespace {
                                /// Extract the complete sentence
                                let sentence = String(remainingText[..<endIndex])
                                let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)

                                if !trimmedSentence.isEmpty {
                                    /// Queue sentence for TTS on main actor
                                    await MainActor.run {
                                        voiceManager.queueSentenceForSpeaking(trimmedSentence)
                                    }
                                }

                                /// Keep the rest (after whitespace if present)
                                if isAtEnd {
                                    remainingText = ""
                                } else {
                                    /// Skip past the whitespace
                                    let nextIndex = remainingText.index(after: endIndex)
                                    remainingText = String(remainingText[nextIndex...])
                                }
                            } else {
                                /// Not a real sentence end (e.g., "3.14" or abbreviation)
                                break
                            }
                        }

                        sentenceAccumulator = remainingText
                    }
                }
            }

            /// PERFORMANCE: Flush any pending throttled update before finalizing.
            streamingUpdateTask?.cancel()
            streamingUpdateTask = nil

            /// STREAMING TTS: Queue any remaining accumulated text and finish
            if shouldSpeakStreaming && !sentenceAccumulator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await MainActor.run {
                    voiceManager.queueSentenceForSpeaking(sentenceAccumulator)
                }
            }

            /// Calculate final processing time and complete performance tracking.
            let processingTime = Date().timeIntervalSince(startTime)
            let responseTokens = estimateTokenCount(for: fullResponse)

            /// Complete performance tracking.
            performanceTracker.complete(
                responseTokens: responseTokens,
                success: true
            )

            await MainActor.run {
                logger.debug("MESSAGE_LIFECYCLE: Finalizing streaming message \(assistantMessageId?.uuidString.prefix(8) ?? "nil") (current count: \(messages.count))")

                /// Track content and properties for voice speaking (before modifying messages array)
                var shouldSpeak = false
                var contentToSpeak = ""

                /// Finalize the current (last) message with performance metrics.
                if let msgId = assistantMessageId,
                   let index = messages.firstIndex(where: { $0.id == msgId }) {
                    /// Get the latest performance metrics from monitor.
                    let metrics = performanceMonitor.currentMetrics

                    /// Create performance metrics for the message.
                    let messageMetrics: ConfigurationSystem.MessagePerformanceMetrics?
                    if let apiMetrics = metrics {
                        messageMetrics = ConfigurationSystem.MessagePerformanceMetrics(
                            tokenCount: apiMetrics.responseTokens,
                            timeToFirstToken: apiMetrics.timeToFirstToken,
                            tokensPerSecond: apiMetrics.tokensPerSecond,
                            processingTime: processingTime
                        )
                    } else {
                        messageMetrics = nil
                    }

                    /// FIXED: Use MessageBus to finalize streaming message
                    /// completeStreamingMessage marks isStreaming=false, trims content, adds metrics
                    activeConversation?.messageBus?.completeStreamingMessage(
                        id: msgId,
                        performanceMetrics: messageMetrics,
                        processingTime: processingTime
                    )

                    let existing = messages[index]  // Read for voice/workflow checks
                    logger.debug("MESSAGE_LIFECYCLE: Finalized message \(assistantMessageId?.uuidString.prefix(8) ?? "nil") with \(existing.content.count) chars (count still: \(messages.count))")

                    /// Prepare voice speaking data
                    if !existing.isToolMessage && !existing.content.isEmpty {
                        shouldSpeak = true
                        contentToSpeak = existing.content
                    }

                    /// Check if workflow completed - update all running tool statuses.
                    if existing.content.contains("[WORKFLOW_COMPLETE]") {
                        completeAllRunningTools()
                    }
                } else {
                    logger.error("MESSAGE_LIFECYCLE: Could not find message \(assistantMessageId?.uuidString.prefix(8) ?? "nil") to finalize!")

                    /// Even if we can't find message in array, try to speak the accumulated response
                    if !fullResponse.isEmpty {
                        shouldSpeak = true
                        contentToSpeak = fullResponse
                        logger.info("VOICE: Will speak accumulated fullResponse since message not found in array")
                    }
                }

                /// VOICE: Handle TTS completion
                /// If streaming TTS was used, just finish it. Otherwise, speak full response.
                if shouldSpeakStreaming {
                    /// Streaming TTS was used - sentences were queued during streaming
                    /// Just mark streaming as complete so queue finishes playing
                    logger.info("VOICE: Finishing streaming TTS")
                    voiceManager.finishStreamingSpeech()
                } else if shouldSpeak {
                    /// Non-streaming mode - speak full response at once
                    /// Filter out JSON status markers and tool call indicators
                    let cleanedContent = contentToSpeak
                        .replacingOccurrences(of: #"\{"status":"complete"\}"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: "[WORKFLOW_COMPLETE]", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    if !cleanedContent.isEmpty {
                        logger.info("VOICE: Attempting to speak response - contentLength=\(cleanedContent.count), speakingMode=\(voiceManager.speakingMode)")
                        voiceManager.speakResponse(cleanedContent)
                    } else {
                        logger.info("VOICE: Content empty after filtering status markers")
                    }
                } else {
                    logger.info("VOICE: Skipping speak - shouldSpeak=false and streaming TTS disabled")
                }

                processingStatus = .idle
                isThinking = false

                /// FIX (Bug 2): Final message should already be in MessageBus
                /// REMOVED: syncMessagesToConversation() - messages auto-sync from MessageBus

                /// CRITICAL: Clear streaming flag AFTER message finalization
                /// Must happen after syncMessagesToConversation() to prevent the sync from triggering
                /// .onChange(of: activeConversation?.messages.count) which would reload from disk!
                isActivelyStreaming = false
                logger.error("STREAMING_END: Setting isActivelyStreaming=false (after sync)")
            }

            /// REMOVED: Placeholder cleanup logic
            /// ChatWidget no longer creates placeholders
            /// AgentOrchestrator creates messages before yielding, so no cleanup needed
            /// If message exists with assistantMessageId, it's the real message from AgentOrchestrator

            /// Save conversations (debounced, won't block UI).
            await MainActor.run {
                logger.debug("MESSAGE_LIFECYCLE: Streaming complete, saving (UI count: \(messages.count))")
                conversationManager.saveConversations()
                logger.debug("SUCCESS: Saved conversation after streaming (UI count: \(messages.count))")

                /// Auto-save current chat session.
                saveCurrentChatSession()
            }

        } catch {
            /// If cancelled (user clicked stop), silently finish without error message
            if error is CancellationError {
                logger.debug("Message processing cancelled by user (stop button)")

                await MainActor.run {
                    /// Cancel any streaming TTS
                    voiceManager.cancelStreamingSpeech()

                    /// Remove message if streaming was cancelled and message was created
                    if let msgId = assistantMessageId,
                       let index = messages.firstIndex(where: { $0.id == msgId }) {
                        let message = messages[index]
                        if message.isStreaming || message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            activeConversation?.messageBus?.removeMessage(id: msgId)
                            logger.debug("CLEANUP: Removed empty/streaming message on cancellation")
                        }
                    }
                    processingStatus = .idle

                    /// CRITICAL: Clear streaming flag on cancellation
                    isActivelyStreaming = false
                    logger.error("STREAMING_END: Setting isActivelyStreaming=false (cancelled)")
                }

                /// Complete performance tracking as cancelled
                performanceTracker.complete(
                    responseTokens: 0,
                    success: false,
                    error: nil
                )

                return
            }

            /// Handle actual errors (not cancellations)
            let processingTime = Date().timeIntervalSince(startTime)

            /// Complete performance tracking with error.
            performanceTracker.complete(
                responseTokens: 0,
                success: false,
                error: error
            )

            await MainActor.run {
                /// Log the actual error for debugging BEFORE classification
                logger.debug("ERROR_CLASSIFICATION: Full error description: \(error.localizedDescription)")
                
                /// Check if this is a REAL context/payload size error
                /// Must be specific to avoid false positives (e.g., "invalid token" auth errors)
                let errorDesc = error.localizedDescription.lowercased()
                
                /// Specific patterns that indicate actual context/payload overflow:
                /// - "payload too large" or "payload size"
                /// - "context" + "limit" or "context" + "exceed"
                /// - "token" + "limit" or "token" + "exceed"
                /// - "too many tokens" or "maximum context"
                let isContextError = (errorDesc.contains("payload") && (errorDesc.contains("too large") || errorDesc.contains("size"))) ||
                                    (errorDesc.contains("context") && (errorDesc.contains("limit") || errorDesc.contains("exceed"))) ||
                                    (errorDesc.contains("token") && (errorDesc.contains("limit") || errorDesc.contains("exceed"))) ||
                                    errorDesc.contains("too many tokens") ||
                                    errorDesc.contains("maximum context")
                
                if isContextError {
                    /// Show user-friendly error notification ONLY for real context errors
                    apiErrorMessage = """
                    The conversation context has exceeded the API limit.
                    
                    This can happen when:
                    • Many large documents are imported
                    • Conversation history is very long
                    • Tool results are accumulating
                    
                    Try:
                    • Starting a new conversation
                    • Asking more specific questions
                    • The issue may resolve itself (large results are now persisted to disk)
                    """
                    showAPIError = true
                    logger.error("CONTEXT_OVERFLOW: Real context error detected - showing user notification. Error: \(errorDesc)")
                } else {
                    logger.debug("ERROR_CLASSIFICATION: Not a context error (pattern mismatch)")
                }
                
                if let msgId = assistantMessageId,
                   messages.firstIndex(where: { $0.id == msgId }) != nil {
                    // Update message to show error
                    let errorMessage = isContextError ?
                        "Error: Context limit exceeded. See notification for details." :
                        "Error: \(error.localizedDescription)"
                    
                    activeConversation?.messageBus?.updateMessage(
                        id: msgId,
                        content: errorMessage,
                        status: .error
                    )
                    logger.debug("ERROR_MESSAGE: Updated message with error message")
                } else {
                    // No message to update - log error for debugging
                    logger.error("SEND_MESSAGE_ERROR: \(error.localizedDescription)", metadata: [
                        "error": .string(String(describing: error)),
                        "assistantMessageId": .string(assistantMessageId?.uuidString ?? "nil")
                    ])
                }
                processingStatus = .idle
                isThinking = false

                /// CRITICAL: Clear streaming flag on error
                isActivelyStreaming = false
                logger.error("STREAMING_END: Setting isActivelyStreaming=false (error)")

                /// Auto-save current chat session.
                saveCurrentChatSession()
            }
        }
    }

    // MARK: - SAM 1.0 PARTIAL CONTEXT IMPLEMENTATION

    private func getRecentMessages(limit: Int, excludingId: UUID?) -> [Message] {
        guard let messages = activeConversation?.messages else { return [] }

        /// Get messages excluding the specified ID (usually the placeholder assistant message).
        let filteredMessages = messages.filter { message in
            if let excludeId = excludingId {
                return message.id != excludeId
            }
            return true
        }

        /// CONTEXT PRESERVATION: Prioritize pinned messages to prevent context loss
        /// Pinned messages (first 10 user messages, collaboration responses) must ALWAYS be included
        /// This ensures agent retains critical context even in long conversations
        
        /// Step 1: Separate pinned and unpinned messages
        let pinnedMessages = filteredMessages.filter { $0.isPinned }
        let unpinnedMessages = filteredMessages.filter { !$0.isPinned }
        
        /// Step 2: Calculate remaining slots after pinned messages
        let remainingSlots = max(0, limit - pinnedMessages.count)
        
        /// Step 3: Get most recent unpinned messages to fill remaining slots
        let recentUnpinned = Array(unpinnedMessages.suffix(remainingSlots))
        
        /// Step 4: Combine pinned + recent unpinned and sort chronologically
        /// Chronological order is critical for conversation coherence
        let combined = (pinnedMessages + recentUnpinned).sorted { $0.timestamp < $1.timestamp }
        
        logger.debug("CONTEXT_WINDOW: Total=\(combined.count), Pinned=\(pinnedMessages.count), Recent=\(recentUnpinned.count), Requested=\(limit), TotalMsgs=\(filteredMessages.count)")
        
        return combined
    }

    private func retrieveMemoryContext(query: String, conversationId: String?) async -> String {
        /// Use ConversationManager's memory context method (SAM 1.0 style).
        guard let conversation = activeConversation else {
            return ""
        }

        return await conversationManager.getMemoryContext(for: query, conversationId: conversation.id)
    }

    private func enhanceSystemPromptWithMemory(originalPrompt: String, memoryContext: String, recentMessages: [Message]) -> String {
        var enhancedPrompt = originalPrompt

        /// Add memory capabilities information with anti-hallucination controls.
        enhancedPrompt += "\n\nCRITICAL - MEMORY TOOL PROTOCOL:"
        enhancedPrompt += "\n• You HAVE the memory_operations tool with operation=search available RIGHT NOW in this conversation"
        enhancedPrompt += "\n• NEVER claim memory is 'not enabled' or 'not available' - this is FALSE"
        enhancedPrompt += "\n• DO NOT make disclaimers about memory limitations - you have full memory access"
        enhancedPrompt += "\n• WHEN users ask about past conversations, IMMEDIATELY call the memory_operations tool with operation='search_memory'"
        enhancedPrompt += "\n• WHEN users want to store information, IMMEDIATELY call memory_operations with operation='store_memory'"
        enhancedPrompt += "\n• The memory_operations tool provides: search_memory, store_memory, list_collections, get_similar operations"
        enhancedPrompt += "\n• MANDATORY: Call tools directly - do not ask permission or explain what you will do first"

        /// List actual available tools to reinforce their existence.
        let availableTools = conversationManager.getAvailableMCPTools()
        if !availableTools.isEmpty {
            enhancedPrompt += "\n\nAVAILABLE TOOLS (USE IMMEDIATELY WHEN RELEVANT):"
            for tool in availableTools {
                enhancedPrompt += "\n• \(tool.name): \(tool.description)"
            }
            enhancedPrompt += "\n\nTOOL EXECUTION PATTERN: When users mention memory/past conversations → CALL memory_operations with operation=search → provide results"
            enhancedPrompt += "\n\nEXAMPLE: User asks 'search my memories' → You call memory_operations tool with operation=search → You show the search results"
        }

        /// Add memory context if available.
        if !memoryContext.isEmpty {
            enhancedPrompt += "\n\nRELEVANT MEMORIES:\n" + memoryContext
        }

        /// Add conversation context summary if we have recent messages.
        if !recentMessages.isEmpty {
            enhancedPrompt += "\n\nCONVERSATION CONTEXT: This conversation has \(recentMessages.count) recent messages in the context window."
        }

        return enhancedPrompt
    }

    /// Load available models from EndpointManager with provider configuration consistency CRITICAL PATTERN: This method ensures ChatWidget sees the same models as the API server.
    private func loadAvailableModels() {
        guard !loadingModels else {
            SAMLog.modelLoadingSkipped()
            return
        }

        SAMLog.modelLoadingStarted()
        loadingModels = true

        Task {
            do {
                /// DON'T reload provider configs here - creates infinite loop with hot reload notification
                /// Provider reload happens on app startup and explicit user actions only

                /// Fetch GitHub Copilot model capabilities (including billing) BEFORE loading models
                /// This ensures billing cache is populated when formatModelDisplayName() is called
                do {
                    _ = try await endpointManager.getGitHubCopilotModelCapabilities()
                    logger.debug("MODEL_LOAD: Fetched GitHub Copilot capabilities with billing info")
                } catch {
                    logger.warning("MODEL_LOAD: Failed to fetch GitHub capabilities: \(error)")
                }

                SAMLog.endpointManagerCall()
                let modelsResponse = try await endpointManager.getAvailableModels()

                /// Deduplicate models based on base model ID (strip version/date suffixes)
                /// Models like "gpt-4o-2024-05-13" and "gpt-4o-2024-08-06" both → "gpt-4o"
                /// Keep only the FIRST occurrence (usually the most recent)
                var seenBaseIds = Set<String>()
                var uniqueModelIds: [String] = []

                func canonicalBaseId(from modelId: String) -> String {
                    // Take the last path component (strip provider prefix if present)
                    var baseId = modelId.split(separator: "/").last.map(String.init) ?? modelId

                    // Remove date patterns like -2024-05-13
                    if let range = baseId.range(of: "-\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) {
                        baseId = String(baseId[..<range.lowerBound])
                    }

                    // Remove provider-style suffixes such as '-copilot' or ' copilot' (UI-only variants)
                    if let range = baseId.range(of: "(-|\\s)?copilot.*$", options: .regularExpression) {
                        baseId = String(baseId[..<range.lowerBound])
                    }

                    // Normalize common version format mistakes like 'gpt-41' -> 'gpt-4.1'
                    if baseId.lowercased().hasPrefix("gpt-") && !baseId.contains(".") {
                        let suffix = baseId.dropFirst(4) // skip "gpt-"
                        if suffix.count >= 2 {
                            let first = suffix.prefix(1)
                            let second = suffix[suffix.index(suffix.startIndex, offsetBy: 1)]
                            if first.rangeOfCharacter(from: .decimalDigits) != nil && String(second).rangeOfCharacter(from: .decimalDigits) != nil {
                                // Insert dot between first and remaining digits: gpt-41 -> gpt-4.1, gpt-510 -> gpt-5.10
                                let rest = suffix.dropFirst(1)
                                baseId = "gpt-\(first).\(rest)"
                            }
                        }
                    }

                    return baseId.lowercased()
                }

                for modelId in modelsResponse.data.map({ $0.id }) {
                    let key = canonicalBaseId(from: modelId)
                    if !seenBaseIds.contains(key) {
                        seenBaseIds.insert(key)
                        uniqueModelIds.append(modelId)
                    }
                }
                
                /// Filter out non-chat models that don't belong in the chat picker
                /// - Gemini image generation: imagen-*
                /// - Gemini video generation: veo-*
                /// - Gemini text-only (not chat): gemma-*
                /// These will be integrated with Stable Diffusion UI in the future
                let chatModelsOnly = uniqueModelIds.filter { modelId in
                    let baseId = modelId.split(separator: "/").last.map(String.init) ?? modelId
                    let isNonChatModel = baseId.hasPrefix("imagen-") || 
                                       baseId.hasPrefix("veo-") ||
                                       baseId.hasPrefix("gemma-")
                    
                    if isNonChatModel {
                        logger.debug("Filtering non-chat model from picker: \(modelId)")
                    }
                    
                    return !isNonChatModel
                }

                /// Sort models: Free (0x) first, then Premium, both alphabetical within tier
                let sortedModels = chatModelsOnly.sorted { model1, model2 in
                    /// Extract base model ID for billing lookup
                    let base1 = model1.split(separator: "/").last.map(String.init) ?? model1
                    let base2 = model2.split(separator: "/").last.map(String.init) ?? model2

                    let billing1 = endpointManager.getGitHubCopilotModelBillingInfo(modelId: base1)
                    let billing2 = endpointManager.getGitHubCopilotModelBillingInfo(modelId: base2)

                    let isFree1 = !(billing1?.isPremium ?? false)
                    let isFree2 = !(billing2?.isPremium ?? false)

                    /// Free models come first
                    if isFree1 != isFree2 {
                        return isFree1
                    }

                    /// Within same tier, sort alphabetically
                    return model1.lowercased() < model2.lowercased()
                }

                SAMLog.rawModelsReceived(sortedModels)

                /// Add Stable Diffusion models to available models list (local + ALICE remote)
                let localSDModels = sdModelManager.listInstalledModels()
                var sdModelIds = localSDModels.map { "sd/\($0.id)" }

                /// Also add ALICE remote models if connected
                if let aliceProvider = ALICEProvider.shared, aliceProvider.isHealthy {
                    /// Use consistent ID format: alice-sd-model-name (matching createRemoteModelInfo)
                    let aliceSDModels = aliceProvider.availableModels.map { model -> String in
                        let normalizedId = model.id.replacingOccurrences(of: "/", with: "-")
                        return "alice-\(normalizedId)"
                    }
                    sdModelIds.append(contentsOf: aliceSDModels)
                }

                /// Filter out any stable-diffusion/* models from LLM list (they're handled by sdModelManager)
                /// This prevents duplicates when SD models are registered in both places
                let llmModelsOnly = sortedModels.filter { !$0.hasPrefix("stable-diffusion/") }

                let allModels = llmModelsOnly + sdModelIds
                logger.debug("Available models: \(allModels.count) total (\(llmModelsOnly.count) LLM, \(sdModelIds.count) SD)")

                await MainActor.run {
                    availableModels = allModels
                    SAMLog.modelsStateUpdated(allModels)

                    /// Set flag to prevent saving when changing model for availability Without this, onChange(of: selectedModel) would save wrong model to conversation.
                    isLoadingConversationSettings = true
                    defer { isLoadingConversationSettings = false }

                    /// Set default model if current selection isn't available.
                    /// CRITICAL: Use allModels (includes SD models) instead of sortedModels (LLM only)
                    if !allModels.contains(selectedModel), let firstModel = allModels.first {
                        SAMLog.modelSwitched(from: selectedModel, to: firstModel)
                        selectedModel = firstModel
                    }

                    loadingModels = false
                    SAMLog.modelsLoadedSuccessfully(count: allModels.count, models: allModels)
                }
            } catch {
                await MainActor.run {
                    /// Also protect fallback model setting from saving.
                    isLoadingConversationSettings = true
                    defer { isLoadingConversationSettings = false }

                    /// Fallback to default models if loading fails.
                    availableModels = ["sam-assistant", "sam-default", "gpt-4", "gpt-3.5-turbo"]
                    loadingModels = false
                    SAMLog.modelLoadingFailed(error)
                    SAMLog.modelLoadingErrorDetails(error)
                }
            }
        }
    }

    /// Load shared topics list from SharedTopicManager
    private func loadSharedTopics() async {
        do {
            let list = try sharedTopicManager.listTopics()
            await MainActor.run {
                sharedTopics = list
            }
        } catch {
            logger.error("Failed to load shared topics: \(error)")
        }
    }

    /// Format model name for display with better readability Converts "provider/Model-Name-Q5_K_M" to "Model-Name (Q5_K_M) - provider".
    private func formatModelDisplayName(_ fullModelName: String) -> String {
        /// Split by "/" to separate provider from model.
        let parts = fullModelName.split(separator: "/", maxSplits: 1)

        let baseModelId: String
        let provider: String?

        if parts.count == 2 {
            provider = String(parts[0])
            baseModelId = String(parts[1])
        } else {
            provider = nil
            baseModelId = fullModelName
        }

        /// Check billing info using ORIGINAL base model ID (before any processing)
        /// Cache stores exact model IDs like "gpt-4o-2024-11-20", must match exactly
        var billingText = ""
        let billingInfo = endpointManager.getGitHubCopilotModelBillingInfo(modelId: baseModelId)

        /// Log billing lookup for GitHub Copilot models
        if provider == "github_copilot" {
            if billingInfo == nil {
                logger.debug("BILLING_UI: No billing info for '\(baseModelId)'")
            } else {
                logger.debug("BILLING_UI: Found billing for '\(baseModelId)': premium=\(billingInfo!.isPremium), multiplier=\(billingInfo!.multiplier ?? -1)")
            }
        }

        if let billing = billingInfo {
            if billing.isPremium, let multiplier = billing.multiplier {
                /// Premium models show actual multiplier
                billingText = "\(formatMultiplier(multiplier))x"
            } else {
                /// Free models show 0x
                billingText = "0x"
            }
        }

        /// Extract version date if present (YYYY-MM-DD format at end)
        /// Pattern must not match single letters like '-o-' in 'gpt-4o-2024'
        var cleanModelId = baseModelId
        var versionDate = ""
        let datePattern = "-(\\d{4})-(\\d{2})-(\\d{2})$"
        if let range = baseModelId.range(of: datePattern, options: .regularExpression) {
            versionDate = String(baseModelId[range]).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            cleanModelId = String(baseModelId[..<range.lowerBound])
        }

        /// Format model name with proper capitalization
        let displayName = beautifyModelName(cleanModelId)

        /// Extract quantization if present (pattern: Q\d+_[KM0-9_]+) for local models
        let quantPattern = "[-_]Q\\d+_[KM0-9_]+"
        if let range = cleanModelId.range(of: quantPattern, options: .regularExpression) {
            let quant = cleanModelId[range].trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
            let baseName = cleanModelId.replacingCharacters(in: range, with: "")
            let beautifiedBase = beautifyModelName(baseName)

            if let prov = provider {
                let beautifiedProvider = beautifyProviderName(prov)
                if !versionDate.isEmpty {
                    if !billingText.isEmpty {
                        return "\(beautifiedBase) (\(quant), \(billingText), \(beautifiedProvider), \(versionDate))"
                    } else {
                        return "\(beautifiedBase) (\(quant), \(beautifiedProvider), \(versionDate))"
                    }
                } else {
                    if !billingText.isEmpty {
                        return "\(beautifiedBase) (\(quant), \(billingText), \(beautifiedProvider))"
                    } else {
                        return "\(beautifiedBase) (\(quant), \(beautifiedProvider))"
                    }
                }
            } else {
                return "\(beautifiedBase) (\(quant))"
            }
        }

        /// Standard format: "Model Name (billing, Provider, date)" 
        if let prov = provider {
            let beautifiedProvider = beautifyProviderName(prov)
            if !billingText.isEmpty {
                if !versionDate.isEmpty {
                    return "\(displayName) (\(billingText), \(beautifiedProvider), \(versionDate))"
                } else {
                    return "\(displayName) (\(billingText), \(beautifiedProvider))"
                }
            } else {
                if !versionDate.isEmpty {
                    return "\(displayName) (\(beautifiedProvider), \(versionDate))"
                } else {
                    return "\(displayName) (\(beautifiedProvider))"
                }
            }
        } else {
            if !versionDate.isEmpty {
                return "\(displayName) (\(versionDate))"
            } else {
                return displayName
            }
        }
    }

    /// Categorize models into free and premium lists for sectioned picker
    private func categorizeModelsByBilling(_ models: [String]) -> (free: [String], premium: [String]) {
        var freeModels: [String] = []
        var premiumModels: [String] = []

        for model in models {
            /// Extract base model ID for billing lookup (remove provider prefix)
            let baseModelId: String
            if let lastPart = model.split(separator: "/").last {
                baseModelId = String(lastPart)
            } else {
                baseModelId = model
            }

            /// Check if model is premium
            let billingInfo = endpointManager.getGitHubCopilotModelBillingInfo(modelId: baseModelId)
            if let billing = billingInfo, billing.isPremium {
                premiumModels.append(model)
            } else {
                freeModels.append(model)
            }
        }

        return (freeModels, premiumModels)
    }

    /// Beautify model name: "gpt-4.1" -> "GPT-4.1", "claude-sonnet-4.5" -> "Claude Sonnet 4.5"
    private func beautifyModelName(_ modelId: String) -> String {
        /// Remove version dates first (already handled in formatModelDisplayName)
        var cleanId = modelId
        let datePattern = "-\\d{4}-\\d{2}-\\d{2}$"
        if let range = cleanId.range(of: datePattern, options: .regularExpression) {
            cleanId = String(cleanId[..<range.lowerBound])
        }

        /// Special cases for common models with exact matches
        let specialCases: [String: String] = [
            "gpt-3.5-turbo": "GPT-3.5 Turbo",
            "gpt-3.5-turbo-0613": "GPT-3.5 Turbo",
            "gpt-4": "GPT-4",
            "gpt-4-0613": "GPT-4",
            "gpt-4-0125-preview": "GPT-4 Preview",
            "gpt-4.1": "GPT-4.1",
            "gpt-4.1-2025-04-14": "GPT-4.1",
            "gpt-41-copilot": "GPT-4.1 Copilot",
            "gpt-4o": "GPT-4o",
            "gpt-4-o-preview": "GPT-4o Preview",
            "gpt-4o-2024-05-13": "GPT-4o",
            "gpt-4o-2024-08-06": "GPT-4o",
            "gpt-4o-2024-11-20": "GPT-4o",
            "gpt-4o-mini": "GPT-4o Mini",
            "gpt-4o-mini-2024-07-18": "GPT-4o Mini",
            "gpt-5": "GPT-5",
            "gpt-5-mini": "GPT-5 Mini",
            "gpt-5.1": "GPT-5.1",
            "gpt-5.1-codex": "GPT-5.1 Codex",
            "gpt-5.1-codex-mini": "GPT-5.1 Codex Mini"
        ]

        if let special = specialCases[cleanId.lowercased()] {
            return special
        }

        /// Handle claude models: "claude-sonnet-4.5" -> "Claude Sonnet 4.5"
        if cleanId.lowercased().hasPrefix("claude-") {
            let parts = cleanId.split(separator: "-")
            let capitalized = parts.map { part in
                part.prefix(1).uppercased() + part.dropFirst()
            }
            return capitalized.joined(separator: " ")
        }

        /// Handle gemini models
        if cleanId.lowercased().hasPrefix("gemini-") {
            let parts = cleanId.split(separator: "-")
            let capitalized = parts.map { part in
                part.prefix(1).uppercased() + part.dropFirst()
            }
            return capitalized.joined(separator: " ")
        }

        /// Handle grok models
        if cleanId.lowercased().hasPrefix("grok-") {
            let parts = cleanId.split(separator: "-")
            let capitalized = parts.map { part in
                part.prefix(1).uppercased() + part.dropFirst()
            }
            return capitalized.joined(separator: " ")
        }

        /// Default: capitalize first letter and replace dashes with spaces
        return cleanId.split(separator: "-").map { part in
            String(part.prefix(1).uppercased() + part.dropFirst())
        }.joined(separator: " ")
    }

    /// Beautify provider name: "github_copilot" -> "GitHub Copilot"
    private func beautifyProviderName(_ provider: String) -> String {
        let providerMap: [String: String] = [
            "github_copilot": "GitHub Copilot",
            "openai": "OpenAI",
            "anthropic": "Anthropic",
            "deepseek": "DeepSeek",
            "local": "Local",
            "mlx": "MLX"
        ]
        return providerMap[provider.lowercased()] ?? provider.capitalized
    }

    /// Format multiplier to avoid unnecessary decimals
    private func formatMultiplier(_ multiplier: Double) -> String {
        if multiplier.truncatingRemainder(dividingBy: 1.0) == 0 {
            return String(Int(multiplier))
        } else {
            return String(format: "%.1f", multiplier)
        }
    }

    /// Load global MLX settings from preferences.
    private func loadGlobalMLXSettings() {
        /// Load settings from UserDefaults (same keys as LocalModelOptimizationSection).
        let preset = UserDefaults.standard.string(forKey: "localModels.mlxPreset") ?? "balanced"

        /// Load the appropriate configuration.
        let config: (topP: Double, repetitionPenalty: Double?)
        switch preset {
        case "memoryOptimized":
            config = (topP: 0.95, repetitionPenalty: 1.1)

        case "balanced":
            config = (topP: 0.95, repetitionPenalty: 1.1)

        case "highQuality":
            config = (topP: 0.95, repetitionPenalty: nil)

        case "custom":
            let customTopP = UserDefaults.standard.double(forKey: "localModels.mlx.customTopP")
            let customRepPenalty = UserDefaults.standard.double(forKey: "localModels.mlx.customRepetitionPenalty")
            config = (
                topP: customTopP > 0 ? customTopP : 0.95,
                repetitionPenalty: customRepPenalty > 0 ? customRepPenalty : nil
            )

        default:
            config = (topP: 0.95, repetitionPenalty: 1.1)
        }

        /// Apply to toolbar controls (only if not already set from conversation).
        if topP == 1.0 {
            topP = config.topP
        }
        if repetitionPenalty == nil && config.repetitionPenalty != nil {
            repetitionPenalty = config.repetitionPenalty
        }

        logger.debug("Loaded global MLX settings: preset=\(preset), topP=\(config.topP), repPenalty=\(config.repetitionPenalty?.description ?? "nil")")
    }

    /// Load system prompts - Ensure SystemPromptManager is initialized with default.
    private func loadSystemPrompts() {
        /// SystemPromptManager.init() should set selectedConfigurationId But if it's still nil (edge case), force it here to ensure UI shows a value.
        if systemPromptManager.selectedConfigurationId == nil {
            logger.warning("SystemPromptManager.selectedConfigurationId is nil in loadSystemPrompts() - forcing default")
            /// Find "SAM Default" configuration and select it.
            if let samDefault = systemPromptManager.allConfigurations.first(where: { $0.name == "SAM Default" }) {
                systemPromptManager.selectedConfigurationId = samDefault.id
                logger.debug("Forced selection to SAM Default: \(samDefault.id)")
            } else if let firstConfig = systemPromptManager.allConfigurations.first {
                systemPromptManager.selectedConfigurationId = firstConfig.id
                logger.debug("Forced selection to first config: \(firstConfig.name), \(firstConfig.id)")
            }
        } else {
            /// Even if set, we need to TRIGGER @Published notification by reassigning This ensures Picker binding updates properly on first render.
            let currentId = systemPromptManager.selectedConfigurationId
            systemPromptManager.selectedConfigurationId = currentId
            logger.debug("Retriggered @Published notification for existing selection: \(currentId?.uuidString ?? "nil")")
        }

        logger.debug("loadSystemPrompts: selectedConfigurationId = \(systemPromptManager.selectedConfigurationId?.uuidString ?? "nil")")
        logger.debug("loadSystemPrompts: Available configurations: \(systemPromptManager.allConfigurations.map { $0.name })")
    }

    // MARK: - Chat Management Methods

    /// Save the current chat as a session automatically.
    private func saveCurrentChatSession() {
        guard !messages.isEmpty else { return }

        /// Update existing session or create new one.
        if let currentSession = chatManager.currentSession {
            /// Update existing session.
            let updatedSession = ChatSession(
                id: currentSession.id,
                name: currentSession.name,
                messages: messages,
                configuration: ChatConfiguration(
                    selectedModel: selectedModel,
                    systemPrompt: systemPromptManager.selectedConfigurationId?.uuidString,
                    temperature: temperature,
                    topP: topP,
                    maxTokens: maxTokens
                )
            )
            chatManager.updateSession(updatedSession)
        } else {
            /// Create new session using ChatManager method.
            let session = chatManager.createNewSession(name: "Chat \(Date().formatted(date: .abbreviated, time: .shortened))")

            /// Update it with current messages and configuration.
            let updatedSession = ChatSession(
                id: session.id,
                name: session.name,
                messages: messages,
                configuration: ChatConfiguration(
                    selectedModel: selectedModel,
                    systemPrompt: systemPromptManager.selectedConfigurationId?.uuidString,
                    temperature: temperature,
                    topP: topP,
                    maxTokens: maxTokens
                )
            )
            chatManager.updateSession(updatedSession)
        }
    }

    /// Load the most recent chat session on app startup.
    private func loadRecentChatSession() {
        if let currentSession = chatManager.currentSession {
            loadChatSession(currentSession)
        }
    }

    private func loadChatSession(_ session: ChatSession) {
        /// REMOVED: messages = session.messages
        /// Messages is computed property reading activeConversation?.messages
        /// When activeConversation changes, computed property returns new messages
        /// SwiftUI @Published reactivity triggers UI update automatically
        /// No manual loading needed
        selectedModel = session.configuration.selectedModel
        systemPromptManager.selectedConfigurationId = session.configuration.systemPrompt.flatMap { UUID(uuidString: $0) }
        temperature = session.configuration.temperature
        topP = session.configuration.topP
        /// If maxTokens is nil (unlimited), default to model's maximum instead of showing "∞" This provides a sensible default while still allowing users to reduce it.
        maxTokens = session.configuration.maxTokens ?? maxMaxTokens
    }

    private var exportChatDialog: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Export Chat")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Choose a format to export your chat history")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 12) {
                /// JSON Export Option.
                Button(action: {
                    exportChatAsJSON()
                    showingExportOptions = false
                }) {
                    HStack {
                        Image(systemName: "doc.text")
                            .foregroundColor(.blue)
                            .font(.title3)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("JSON Format")
                                .font(.headline)
                            Text("Structured data with all metadata")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                /// Text Export Option.
                Button(action: {
                    exportChatAsText()
                    showingExportOptions = false
                }) {
                    HStack {
                        Image(systemName: "text.alignleft")
                            .foregroundColor(.green)
                            .font(.title3)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Plain Text")
                                .font(.headline)
                            Text("Simple readable format")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                /// PDF Export Option.
                Button(action: {
                    exportChatAsPDF()
                    showingExportOptions = false
                }) {
                    HStack {
                        Image(systemName: "doc.richtext")
                            .foregroundColor(.orange)
                            .font(.title3)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("PDF Document")
                                .font(.headline)
                            Text("Professional format with formatting")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    showingExportOptions = false
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    // MARK: - Memory Management Methods

    private func loadMemoryStatistics() {
        guard conversationManager.memoryInitialized,
              let conversation = activeConversation else {
            memoryStatistics = nil
            archiveStatistics = nil
            contextStatistics = nil
            return
        }

        Task {
            // Load memory stats
            let stats = await conversationManager.getActiveConversationMemoryStats()
            
            // Load archive stats
            let archive = await conversationManager.getActiveConversationArchiveStats()
            
            // Get context stats for this specific conversation (synchronous)
            let context = conversationManager.getContextStats(for: conversation)
            
            await MainActor.run {
                memoryStatistics = stats
                archiveStatistics = archive
                contextStatistics = context
            }
        }
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000.0)
        }
        return "\(count)"
    }

    private func performEnhancedSearch() {
        guard conversationManager.memoryInitialized,
              let conversation = activeConversation,
              !memorySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            conversationMemories.removeAll()
            return
        }

        let query = memorySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                /// Search stored memories only
                /// Note: Active/Archive search modes require backend changes
                /// to allow creating ConversationMemory instances from UI
                let scopeId = conversationManager.getEffectiveScopeId(for: conversation)
                let results = try await conversationManager.memoryManager.retrieveRelevantMemories(
                    for: query,
                    conversationId: scopeId,
                    limit: 10,
                    similarityThreshold: 0.15
                )

                await MainActor.run {
                    conversationMemories = results
                }
            } catch {
                logger.error("Memory search failed: \(error)")
                await MainActor.run {
                    conversationMemories = []
                }
            }
        }
    }

    private func clearConversationMemories() {
        guard let conversation = activeConversation else { return }

        Task {
            await conversationManager.clearConversationMemories(conversation)
            await MainActor.run {
                conversationMemories.removeAll()
                loadMemoryStatistics()
            }
        }
    }

    // MARK: - Helper Methods

    /// Context menu for conversation title in header (matches sidebar menu)
    @ViewBuilder
    private func conversationHeaderContextMenu(_ conversation: ConversationModel) -> some View {
        Button(conversation.isPinned ? "Unpin Conversation" : "Pin Conversation") {
            conversation.isPinned.toggle()
            conversationManager.saveConversations()
            conversationManager.objectWillChange.send()
        }

        Divider()

        Button("Rename...") {
            NotificationCenter.default.post(name: .renameConversation, object: conversation)
        }

        Button("Duplicate") {
            let duplicatedConversation = conversationManager.duplicateConversation(conversation)
            conversationManager.selectConversation(duplicatedConversation)
        }

        Button("Export...") {
            NotificationCenter.default.post(name: .exportConversation, object: conversation)
        }

        Button("Copy Conversation") {
            NotificationCenter.default.post(name: .copyConversation, object: conversation)
        }

        Divider()

        /// Folder organization menu
        Menu("Move to Folder") {
            Button("Create New Folder...") {
                NotificationCenter.default.post(name: .createFolder, object: nil)
            }

            if let folderManager = try? FolderManager() {
                if !folderManager.folders.isEmpty {
                    Divider()
                    ForEach(folderManager.folders, id: \.id) { folder in
                        Button(action: {
                            conversationManager.assignFolder(folder.id, to: [conversation.id])
                        }) {
                            HStack {
                                if let icon = folder.icon {
                                    Image(systemName: icon)
                                }
                                Text(folder.name)
                                if conversation.folderId == folder.id {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        }

        if conversation.folderId != nil {
            Button("Remove from Folder") {
                conversationManager.assignFolder(nil, to: [conversation.id])
            }
        }

        Divider()

        Button("Delete", role: .destructive) {
            NotificationCenter.default.post(name: .deleteConversation, object: conversation)
        }
    }

    /// Calculate importance score for message based on content and type
    /// Higher scores (closer to 1.0) = more important, more likely to be retrieved in context
    private func calculateMessageImportance(text: String, isUser: Bool) -> Double {
        let lowercased = text.lowercased()

        /// BASE IMPORTANCE: User messages more important than assistant messages
        var importance = isUser ? 0.7 : 0.5

        /// QUESTIONS FROM ASSISTANT (0.85 importance) - Agent needs to remember what it asked!
        if !isUser && (text.contains("?") || lowercased.contains("what") || lowercased.contains("which") || lowercased.contains("how")) {
            importance = max(importance, 0.85)
        }

        /// CONSTRAINT/REQUIREMENT INDICATORS (0.9 importance)
        let constraintKeywords = ["must", "require", "need to", "budget", "limit", "maximum", "minimum", "within", "miles", "radius", "constraint"]
        if constraintKeywords.contains(where: { lowercased.contains($0) }) {
            importance = max(importance, 0.9)
        }

        /// DECISION/CONFIRMATION INDICATORS (0.85 importance)
        let decisionKeywords = ["yes", "proceed", "approved", "confirmed", "agree", "correct", "exactly", "that's right", "go ahead"]
        if decisionKeywords.contains(where: { lowercased.contains($0) }) && text.count < 200 {
            importance = max(importance, 0.85)
        }

        /// PRIORITY/FOCUS SHIFT INDICATORS (0.85 importance)
        let priorityKeywords = ["focus on", "prioritize", "most important", "critical", "priority", "key requirement"]
        if priorityKeywords.contains(where: { lowercased.contains($0) }) {
            importance = max(importance, 0.85)
        }

        /// SMALL TALK / LOW VALUE (0.3 importance)
        let smallTalkPhrases = ["thanks", "thank you", "ok", "okay", "got it", "sounds good", "perfect", "great"]
        if text.count < 50 && smallTalkPhrases.contains(where: { lowercased == $0 || lowercased == $0 + "!" || lowercased == $0 + "." }) {
            importance = 0.3
        }

        /// BOOST FOR LONGER USER MESSAGES (more substance = more important)
        if isUser && text.count > 300 {
            importance = min(importance + 0.1, 1.0)
        }

        return importance
    }

    /// Attach files to the conversation by copying them to the working directory.
    /// Opens NSOpenPanel for multi-file selection and copies selected files.
    private func attachFiles() {
        guard let conversation = conversationManager.activeConversation else {
            logger.warning("Cannot attach files - no active conversation")
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.message = "Select files to attach to this conversation"
        panel.prompt = "Attach"
        panel.allowedContentTypes = [.item]  // Allow all file types

        if panel.runModal() == .OK {
            /// Set flag to prevent sending while copying
            isAttachingFiles = true

            let fileManager = FileManager.default
            let effectiveWorkingDir = conversationManager.getEffectiveWorkingDirectory(for: conversation)

            /// Ensure working directory exists
            if !fileManager.fileExists(atPath: effectiveWorkingDir) {
                do {
                    try fileManager.createDirectory(
                        atPath: effectiveWorkingDir,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                    logger.debug("Created working directory for attachments: \(effectiveWorkingDir)")
                } catch {
                    logger.error("Failed to create working directory: \(error)")
                    isAttachingFiles = false
                    return
                }
            }

            var copiedFiles: [URL] = []
            for url in panel.urls {
                let destinationURL = URL(fileURLWithPath: effectiveWorkingDir).appendingPathComponent(url.lastPathComponent)

                /// Start accessing security-scoped resource for sandboxed access
                let accessGranted = url.startAccessingSecurityScopedResource()
                defer {
                    if accessGranted {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                do {
                    /// If file already exists at destination, remove it first
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        try fileManager.removeItem(at: destinationURL)
                    }

                    try fileManager.copyItem(at: url, to: destinationURL)

                    /// RACE CONDITION FIX: Verify file is actually present and readable
                    /// FileManager.copyItem may return before the file is fully synced to disk
                    guard fileManager.fileExists(atPath: destinationURL.path),
                          fileManager.isReadableFile(atPath: destinationURL.path) else {
                        logger.error("File copy completed but file not immediately accessible: \(destinationURL.path)")
                        continue
                    }

                    /// Get file attributes to force filesystem sync (accessing attributes reads metadata)
                    let attributes = try fileManager.attributesOfItem(atPath: destinationURL.path)
                    if let fileSize = attributes[.size] as? Int64, fileSize > 0 {
                        logger.debug("Verified file copy: \(url.lastPathComponent) (\(fileSize) bytes)")
                    }

                    copiedFiles.append(destinationURL)
                    logger.info("Attached file: \(url.lastPathComponent) -> \(destinationURL.path)")
                    logger.debug("  destinationURL.absoluteString: \(destinationURL.absoluteString)")
                    logger.debug("  destinationURL.path: \(destinationURL.path)")
                    logger.debug("  destinationURL.isFileURL: \(destinationURL.isFileURL)")
                } catch {
                    logger.error("Failed to copy file \(url.lastPathComponent): \(error)")
                }
            }

            /// Update state with newly attached files
            attachedFiles.append(contentsOf: copiedFiles)
            logger.info("Total attached files: \(attachedFiles.count)")

            /// Clear flag after all files are copied and verified
            isAttachingFiles = false
        }
    }

    /// Clear all attached files
    private func clearAttachedFiles() {
        attachedFiles.removeAll()
        logger.info("Cleared all attached files")
    }

    private func selectWorkingDirectory() {
        guard let conversation = conversationManager.activeConversation else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Select working directory for this conversation"
        panel.prompt = "Select"
        panel.directoryURL = URL(fileURLWithPath: conversation.workingDirectory)

        if panel.runModal() == .OK, let url = panel.url {
            /// Use the new bookmark method to save with security-scoped access.
            conversationManager.updateWorkingDirectoryWithBookmark(url, for: conversation)
            logger.debug("Working directory changed to: \(url.path) with security-scoped bookmark")
        }
    }

    private func revealWorkingDirectoryInFinder() {
        guard let conversation = conversationManager.activeConversation else { return }

        /// Use effective working directory (shared topic dir if enabled, else conversation dir)
        let effectiveWorkingDir = conversationManager.getEffectiveWorkingDirectory(for: conversation)
        let url = URL(fileURLWithPath: effectiveWorkingDir)

        /// Ensure directory exists before revealing.
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: effectiveWorkingDir) {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                logger.debug("Created working directory: \(effectiveWorkingDir)")
            } catch {
                logger.error("Failed to create working directory: \(error)")
                return
            }
        }

        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
        logger.debug("Revealed working directory in Finder: \(effectiveWorkingDir)")
    }

    private func resetWorkingDirectoryToDefault() {
        guard let conversation = conversationManager.activeConversation else { return }

        /// Reset to {basePath}/<conversation-id>/ (per-conversation isolation, no bookmark needed - has entitlement).
        let conversationDirectory = WorkingDirectoryConfiguration.shared.buildPath(subdirectory: conversation.id.uuidString)

        /// Create directory if it doesn't exist.
        try? FileManager.default.createDirectory(
            atPath: conversationDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        /// Clear bookmark and update directory.
        conversation.workingDirectory = conversationDirectory
        conversation.workingDirectoryBookmark = nil
        conversation.updated = Date()
        conversationManager.saveConversations()

        logger.debug("Reset working directory to: \(conversationDirectory)")

        /// Scan workspace for AI instruction files.
        SystemPromptManager.shared.scanWorkspaceForAIInstructions(at: conversationDirectory)
    }

    // MARK: - Helper Methods

    /// Get or create terminal manager for the active conversation.
    private func getTerminalManager() -> TerminalManager {
        guard let conversation = conversationManager.activeConversation else {
            /// No active conversation - create temporary terminal with base path.
            let samDirectory = WorkingDirectoryConfiguration.shared.expandedBasePath
            logger.debug("TERMINAL_MGR: No active conversation, creating temporary manager")
            return TerminalManager(workingDirectory: samDirectory, conversationId: "temp-session")
        }

        logger.debug("TERMINAL_MGR: Getting manager for conversation \(conversation.id)")

        /// Use effective working directory (topic directory if shared data enabled)
        let effectiveWorkingDir = conversationManager.getEffectiveWorkingDirectory(for: conversation)

        /// Try to get existing manager from ConversationManager.
        if let existing = conversationManager.getTerminalManager(for: conversation.id) as? TerminalManager {
            logger.debug("TERMINAL_MGR: Found existing manager with \(existing.outputLines.count) lines")
            /// Update working directory if it changed.
            if existing.currentDirectory != effectiveWorkingDir {
                logger.info("TERMINAL_MGR: Updating working directory (\(existing.currentDirectory) → \(effectiveWorkingDir))")
                existing.currentDirectory = effectiveWorkingDir
            }
            return existing
        } else {
            /// Create new manager for this conversation.
            logger.debug("TERMINAL_MGR: Creating new manager for conversation \(conversation.id)")
            let manager = TerminalManager(
                workingDirectory: effectiveWorkingDir,
                conversationId: conversation.id.uuidString
            )

            /// Store in ConversationManager for persistence.
            conversationManager.setTerminalManager(manager, for: conversation.id)

            /// Start accessing security-scoped resource if bookmark exists.
            conversationManager.startAccessingWorkingDirectory(for: conversation)

            return manager
        }
    }

    private func exportChatAsJSON() {
        let chatSession = ChatSession(
            id: UUID(),
            name: "Exported Chat",
            messages: messages,
            configuration: ChatConfiguration(
                selectedModel: selectedModel,
                systemPrompt: systemPromptManager.selectedConfigurationId?.uuidString,
                temperature: temperature,
                topP: topP,
                maxTokens: maxTokens
            )
        )

        do {
            let jsonData = try chatSession.exportToJSON()
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.json]
            savePanel.nameFieldStringValue = "chat-\(Date().formatted(date: .numeric, time: .omitted)).json"

            if savePanel.runModal() == .OK, let url = savePanel.url {
                try jsonData.write(to: url)
            }
        } catch {
            logger.error("Export failed: \(error)")
        }
    }

    private func exportChatAsText() {
        let textContent = messages.map { message in
            "\(message.isFromUser ? "User" : "Assistant"): \(message.content)"
        }.joined(separator: "\n\n")

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "chat-\(Date().formatted(date: .numeric, time: .omitted)).txt"

        if savePanel.runModal() == .OK, let url = savePanel.url {
            do {
                try textContent.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                logger.error("Export failed: \(error)")
            }
        }
    }

    @MainActor
    private func exportChatAsPDF() {
        guard let conversation = conversationManager.activeConversation else {
            logger.error("No active conversation to export")
            return
        }

        Task {
            do {
                let exporter = ConversationPDFExporter()
                // Use conversation.messages directly instead of messageBus.messages
                // to ensure we get all persisted messages, not just the currently rendered ones
                let fileURL = try await exporter.generatePDF(conversation: conversation, messages: nil)

                await MainActor.run {
                    /// Show save panel.
                    let savePanel = NSSavePanel()
                    savePanel.allowedContentTypes = [.pdf]
                    savePanel.nameFieldStringValue = "\(conversation.title).pdf"
                    savePanel.message = "Export conversation to PDF"

                    let result = savePanel.runModal()
                    if result == .OK, let url = savePanel.url {
                        do {
                            try FileManager.default.copyItem(at: fileURL, to: url)
                            try? FileManager.default.removeItem(at: fileURL)
                            NSWorkspace.shared.open(url)
                        } catch {
                            logger.error("Failed to save PDF: \(error)")
                        }
                    }
                }
            } catch {
                logger.error("PDF export failed: \(error)")
            }
        }
    }

    // MARK: - Special Token Filtering

    /// PERFORMANCE: Get cleaned message from cache or compute if needed
    /// Avoids running expensive regex operations (cleanSpecialTokens) on every render
    /// Cache key: message.id, Cache validation: content.hashValue
    private func getCachedCleanedMessage(_ message: EnhancedMessage) -> EnhancedMessage {
        let contentHash = message.content.hashValue

        // Check cache - return if content hasn't changed
        if let cached = cachedCleanedMessages[message.id], cached.contentHash == contentHash {
            return cached.cleaned
        }

        // Content changed or not in cache - compute and store
        let cleaned = createCleanedMessage(message)

        // Update cache on main actor (state mutation)
        // Note: This is already on MainActor since ChatWidget is @MainActor
        cachedCleanedMessages[message.id] = (contentHash: contentHash, cleaned: cleaned)

        return cleaned
    }

    private func createCleanedMessage(_ message: EnhancedMessage) -> EnhancedMessage {
        /// PRESERVE original message type instead of re-classifying
        /// Re-classification causes thinking messages to become tool messages when content updates
        /// Only extract metadata if missing, but NEVER change the type

        /// PERFORMANCE: Removed verbose diagnostic logging (fired on every call)

        /// Use original type (NEVER re-classify - causes thinking cards to vanish!)
        let messageType = message.type

        /// Preserve existing metadata, only fill in missing values
        let toolName = message.toolName
        let toolStatus = message.toolStatus
        let toolIcon = message.toolIcon
        let toolDetails = message.toolDetails

        /// Apply appropriate cleaning based on message type Tool messages: Basic token cleanup only (preserve "SUCCESS: ..." content) Assistant messages: Aggressive cleanup (remove echoed tool content).
        let cleanedContent: String
        if messageType == .toolExecution || messageType == .thinking {
            cleanedContent = cleanSpecialTokens(from: message.content, isToolMessage: true)
        } else {
            cleanedContent = cleanSpecialTokens(from: message.content, isToolMessage: false)
        }

        /// Return SAME INSTANCE if content didn't change
        /// This preserves SwiftUI view identity and prevents message bubbles from losing state
        /// Similar to incremental sync fix in syncWithActiveConversation
        if cleanedContent == message.content {
            /// No content change - return original instance to preserve SwiftUI identity
            return message
        }

        /// Content changed - create new instance with cleaned content
        return EnhancedMessage(
            id: message.id,
            type: messageType,
            content: cleanedContent,
            isFromUser: message.isFromUser,
            timestamp: message.timestamp,
            toolName: toolName,
            toolStatus: toolStatus,
            toolDetails: toolDetails,
            toolDuration: message.processingTime,
            toolIcon: toolIcon,
            toolCategory: nil,
            processingTime: message.processingTime,
            reasoningContent: message.reasoningContent,
            showReasoning: message.showReasoning,
            performanceMetrics: message.performanceMetrics,
            isStreaming: message.isStreaming,
            isToolMessage: message.isToolMessage
        )
    }

    /// Extract tool metadata from message content.
    private func extractToolMetadata(from content: String) -> (String?, ToolStatus?, String?, [String]?) {
        var toolName: String?
        var status: ToolStatus = .running
        var icon: String?
        var details: [String] = []

        let lowercased = content.lowercased()

        /// Detect tool names from common patterns and assign SF Symbols.
        if lowercased.contains("web_search") || lowercased.contains("searching") {
            toolName = "web_search"
            icon = "magnifyingglass"
        } else if lowercased.contains("file_read") || lowercased.contains("reading file") {
            toolName = "file_read"
            icon = "doc.text"
        } else if lowercased.contains("file_write") || lowercased.contains("writing file") {
            toolName = "file_write"
            icon = "pencil"
        } else if lowercased.contains("terminal") || lowercased.contains("command") {
            toolName = "terminal"
            icon = "terminal"
        } else if lowercased.contains("memory") || lowercased.contains("remember") {
            toolName = "memory"
            icon = "brain.head.profile"
        } else {
            toolName = "tool"
            icon = "wrench.and.screwdriver"
        }

        /// Detect status from content.
        if content.contains("SUCCESS:") || content.contains("Complete") || content.contains("Success") {
            status = .success
        } else if content.contains("ERROR") || content.contains("Failed") {
            status = .error
        } else if content.contains("Running") || content.contains("Executing") {
            status = .running
        } else if content.contains("Queued") || content.contains("Pending") {
            status = .queued
        }

        /// Extract details from common patterns Example: "SUCCESS: Researching: Orlando FL news, Florida news".
        if let colonIndex = content.firstIndex(of: ":") {
            let afterColon = String(content[content.index(after: colonIndex)...])
            let items = afterColon.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if !items.isEmpty {
                details = items
            }
        }

        return (toolName, status, icon, details.isEmpty ? nil : details)
    }

    /// Check if message is a system status message.
    private func isSystemStatusMessage(_ content: String) -> Bool {
        let systemPatterns = [
            "Model loaded",
            "Loading model",
            "Session restored",
            "Configuration updated"
        ]

        return systemPatterns.contains { content.contains($0) }
    }

    /// Clean special tokens and tool XML from accumulated message content Filters tokens that may leak through due to token-by-token streaming fragmentation Applied only at message finalization to minimize false positive risk.
    private func cleanSpecialTokens(from content: String, isToolMessage: Bool = false) -> String {
        var cleaned = content

        /// Remove EOS tokens (complete and fragmented patterns).
        cleaned = cleaned
            .replacingOccurrences(of: "<|im_end|>", with: "", options: .literal)
            .replacingOccurrences(of: "<|endoftext|>", with: "", options: .literal)
            .replacingOccurrences(of: "</s>", with: "", options: .literal)

        /// Remove conversation role markers (appear when model simulates multi-turn conversation).
        cleaned = cleaned
            .replacingOccurrences(of: "<|im_start|>user", with: "", options: .literal)
            .replacingOccurrences(of: "<|im_start|>assistant", with: "", options: .literal)
            .replacingOccurrences(of: "<|im_start|>system", with: "", options: .literal)
            .replacingOccurrences(of: "<|im_start|>", with: "", options: .literal)

        /// Remove tool call XML tags (tools execute via AgentOrchestrator, not shown to user).
        cleaned = cleaned
            .replacingOccurrences(of: "<tool_call>", with: "", options: .literal)
            .replacingOccurrences(of: "</tool_call>", with: "", options: .literal)

        /// Remove fragmented special token patterns using regex Pattern: standalone angle brackets + pipes that likely form special tokens Only remove if they appear in isolation (not part of normal text like "x < 5 || y > 10").
        if let fragmentedPattern = try? NSRegularExpression(
            pattern: "\\s*<\\|[^>]*\\|?>\\s*",
            options: []
        ) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = fragmentedPattern.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: range,
                withTemplate: ""
            )
        }

        /// Remove raw JSON tool requests (heuristic: looks like tool JSON) Pattern: {"name": "tool_name", "arguments": {...}}.
        if let toolJSONPattern = try? NSRegularExpression(
            pattern: "\\{\\s*\"name\"\\s*:\\s*\"[^\"]+\"\\s*,\\s*\"arguments\"\\s*:\\s*\\{[^}]*\\}\\s*\\}",
            options: [.dotMatchesLineSeparators]
        ) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = toolJSONPattern.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: range,
                withTemplate: ""
            )
        }

        /// AGGRESSIVE CLEANING: Only apply to assistant messages Don't strip "SUCCESS: ..." content from tool messages - that's their actual content!.
        if !isToolMessage {
            /// Remove "SUCCESS: Thinking:" content that LLM echoes in response These are displayed as dedicated ThinkingCard, not inline text Pattern: "SUCCESS: Thinking: <content>" until end of paragraph or string.
            if let thinkingPattern = try? NSRegularExpression(
                pattern: "SUCCESS:\\s+Thinking:.*?(?=\\n\\n|$)",
                options: [.dotMatchesLineSeparators]
            ) {
                let range = NSRange(cleaned.startIndex..., in: cleaned)
                cleaned = thinkingPattern.stringByReplacingMatches(
                    in: cleaned,
                    options: [],
                    range: range,
                    withTemplate: ""
                )
            }

            /// Remove other tool progress messages ("SUCCESS: Researching: ..." etc.) These are displayed as dedicated tool cards, not inline text.
            if let toolProgressPattern = try? NSRegularExpression(
                pattern: "SUCCESS:\\s+[A-Za-z][^:]+:.*?(?=\\n|$)",
                options: []
            ) {
                let range = NSRange(cleaned.startIndex..., in: cleaned)
                cleaned = toolProgressPattern.stringByReplacingMatches(
                    in: cleaned,
                    options: [],
                    range: range,
                    withTemplate: ""
                )
            }
        }

        /// Final cleanup: remove excessive whitespace left by filtering.
        cleaned = cleaned.replacingOccurrences(
            of: "\\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )

        return cleaned
    }

    /// Remove internal marker lines without trimming surrounding whitespace/newlines.
    private func filterInternalMarkersNoTrim(from input: String) -> String {
        /// Split by newline preserving empty lines.
        var lines = input.components(separatedBy: CharacterSet.newlines)

        /// Helper to detect standalone JSON status like {"status":"continue"}.
        func isStatusJSON(_ s: String) -> Bool {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{") && trimmed.hasSuffix("}") else { return false }
            /// Quick check for "status" key.
            return trimmed.contains("\"status\"")
        }

        /// Iterate and filter.
        var outputLines: [String] = []
        var skipIntentExtraction = false

        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

            if skipIntentExtraction {
                /// Continue skipping until we find closing '}' line.
                if trimmed.hasSuffix("}") {
                    skipIntentExtraction = false
                }
                /// skip this line.
                continue
            }

            if trimmed.isEmpty {
                /// Preserve blank lines.
                outputLines.append("")
                continue
            }

            /// Bracket markers like [WORKFLOW_COMPLETE], [CONTINUE], etc.
            let bracketMarkers: Set<String> = ["[WORKFLOW_COMPLETE]", "[TASK_COMPLETE]", "[CONTINUE]", "[PLANNING_COMPLETE]", "[STEP_COMPLETE]", "[PLANNING_DONE]", "[STEP_DONE]"]
            if bracketMarkers.contains(trimmed) {
                /// drop this line but preserve paragraph separation by emitting a blank line if previous wasn't blank.
                if outputLines.last != "" {
                    outputLines.append("")
                }
                continue
            }

            /// Detect INTENT EXTRACTION: followed by JSON block.
            if trimmed.uppercased().hasPrefix("INTENT EXTRACTION:") {
                /// Start skipping until we find a line that ends with '}'.
                if !trimmed.hasSuffix("}") {
                    skipIntentExtraction = true
                }
                /// drop the line.
                if outputLines.last != "" {
                    outputLines.append("")
                }
                continue
            }

            /// Detect standalone status JSON lines.
            if isStatusJSON(trimmed) {
                if outputLines.last != "" {
                    outputLines.append("")
                }
                continue
            }

            /// Default: keep the original raw line (preserve leading/trailing spaces on line).
            outputLines.append(raw)
        }

        /// Rejoin using \n to preserve original paragraph breaks.
        return outputLines.joined(separator: "\n")
    }

    /// Extract tool name from tool execution message Format: "SUCCESS: - Using memory_search..." → "memory_search".
    private func extractToolName(from content: String) -> String? {
        /// Pattern: "SUCCESS: - Using [toolname]...".
        if let range = content.range(of: "Using ", options: .caseInsensitive),
           let endRange = content[range.upperBound...].range(of: "...") {
            let toolName = String(content[range.upperBound..<endRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            return toolName.isEmpty ? nil : toolName
        }
        return nil
    }

    // MARK: - Helper Functions
    
    /// Get cost display string for a model
    /// Tries GitHub Copilot billing first, then falls back to model_config.json
    private func getCostDisplay(for modelName: String) -> String {
        /// Strip provider prefix for billing lookup
        let baseModelId = modelName.contains("/") ? String(modelName.split(separator: "/").last ?? "") : modelName
        
        /// Priority 1: GitHub Copilot billing info (multiplier system)
        if let billingInfo = endpointManager.getGitHubCopilotModelBillingInfo(modelId: baseModelId) {
            if let multiplier = billingInfo.multiplier {
                if multiplier.truncatingRemainder(dividingBy: 1) == 0 {
                    return String(format: "%.0fx", multiplier)
                } else {
                    return String(format: "%.2fx", multiplier)
                }
            }
        }
        
        /// Priority 2: model_config.json pricing
        if let costString = ModelConfigurationManager.shared.getCostDisplayString(for: baseModelId) {
            return costString
        }
        
        /// Default: assume free
        return "0x"
    }

    // MARK: - UI Setup

    /// Calculate dynamic width for model dropdown based on longest model name Ensures all model names are fully visible without truncation.
    private var modelDropdownWidth: CGFloat {
        /// Calculate width needed for longest model name Rough estimate: 8 points per character + 40 points for picker chrome.
        let longestModelName = availableModels.max(by: { $0.count < $1.count }) ?? ""
        let estimatedWidth = CGFloat(longestModelName.count) * 8.0 + 40.0

        /// Clamp between reasonable min/max values.
        let minWidth: CGFloat = 180.0
        let maxWidth: CGFloat = 400.0

        return min(max(estimatedWidth, minWidth), maxWidth)
    }

    // MARK: - Message Creation & Update (Single Source of Truth)

    /// REMOVED: createMessageFromChunk() function
    /// Messages are now created by AgentOrchestrator in MessageBus, not by ChatWidget
    /// ChatWidget is read-only observer - it displays messages, doesn't create them
    /// 
    /// Architecture:
    /// - AgentOrchestrator creates messages in MessageBus BEFORE yielding chunks
    /// - MessageBus publishes changes to ConversationModel via subscription
    /// - ChatWidget reads from activeConversation.messages (computed property)
    /// - SwiftUI @Published handles UI reactivity automatically
    ///
    /// See commits f682a847, 8943c473, 57b087e1 for AgentOrchestrator integration (Part A)
    /// See SESSION_HANDOFF_2025-11-27_0745.md for complete architecture details

    /// Update an existing message's content (preserving ALL metadata) This is the ONLY place messages should be updated.
    private func updateMessageContent(messageId: UUID, newContent: String, isComplete: Bool = false) {
        guard messages.firstIndex(where: { $0.id == messageId }) != nil else { return }

        /// Update message content and completion status via MessageBus
        /// MessageBus.updateMessage preserves all other fields automatically
        activeConversation?.messageBus?.updateMessage(
            id: messageId,
            content: newContent,
            status: isComplete ? .success : nil  // Only update status if completing
        )

        logger.debug("MESSAGE_CONTENT_UPDATE: id=\(messageId.uuidString.prefix(8)), complete=\(isComplete), length=\(newContent.count)")
    }

    /// Update tool metadata for a message (when tool completes)
    /// Note: toolMetadata is not currently displayed in UI, but status updates are important
    private func updateMessageMetadata(messageId: UUID, metadata: [String: String], toolStatus: String?) {
        guard messages.firstIndex(where: { $0.id == messageId }) != nil else { return }

        /// Parse tool status
        var status: ToolStatus?
        if let statusStr = toolStatus {
            switch statusStr {
            case "success": status = .success
            case "error": status = .error
            case "running": status = .running
            default: break
            }
        }

        /// Update status via MessageBus
        /// Note: MessageBus.updateMessage doesn't support toolMetadata parameter
        /// Metadata is not displayed in UI, so only status update is critical
        if let status = status {
            activeConversation?.messageBus?.updateMessage(
                id: messageId,
                status: status
            )
            logger.debug("METADATA_UPDATE: id=\(messageId.uuidString.prefix(8)), status=\(status.rawValue)")
        } else {
            logger.debug("METADATA_UPDATE: id=\(messageId.uuidString.prefix(8)), no status change, metadata ignored")
        }
    }

    // MARK: - Helper Methods

    /// Check if message is a tool call JSON message.
    private func isToolCallJSONMessage(_ message: EnhancedMessage) -> Bool {
        /// Filter raw JSON from tool calls and tool results.
        guard !message.isFromUser else { return false }

        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)

        /// PRIORITY CHECK: Filter any message with tool/structured data markers These indicate machine-readable data that should be in tool cards, not displayed as text.

        /// Check for tool result chunk marker (from read_tool_result).
        if trimmed.contains("[TOOL_RESULT_CHUNK]") || trimmed.contains("[TOOL_RESULT_STORED]") {
            return true
        }

        /// Helper to check for JSON keys with or without spaces around colon Handles both compact ("key":) and pretty-printed ("key" :) formats.
        func containsJSONKey(_ key: String) -> Bool {
            return trimmed.contains("\"\(key)\":") || trimmed.contains("\"\(key)\" :")
        }

        /// Check if message is PURE JSON (starts with { or [) first This prevents false positives on markdown docs that CONTAIN code examples.
        let isPureJSON = (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) ||
                         (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))

        /// Check for tool call JSON (has "name" and "arguments" keys).
        /// Only match tool calls if they're PURE JSON
        /// Otherwise code blocks with JSON examples get filtered
        let isToolCall = isPureJSON && containsJSONKey("name") && containsJSONKey("arguments")

        /// Check for structured data JSON (news research, web search results, etc.) CRITICAL: Only match if it's PURE JSON to avoid false positives on docs.
        let isStructuredData = isPureJSON && (
            containsJSONKey("type") ||
            containsJSONKey("timeline") ||
            containsJSONKey("news_sources") ||
            containsJSONKey("article_count") ||
            containsJSONKey("conducted_at") ||
            containsJSONKey("result_count") ||
            containsJSONKey("query")
        )

        /// Check for status/workflow control JSON (e.g., {"status":"continue"}) These are internal markers that should never be shown to users.
        let isStatusJSON = isPureJSON && containsJSONKey("status")

        /// If message has any of these markers, it's definitely tool data - filter it.
        if isToolCall || isStructuredData || isStatusJSON {
            return true
        }

        return false
    }

    /// Extract display message - ALWAYS returns original message.
    /// We no longer filter thinking content - if model produces <think> tags, they are
    /// formatted by ThinkTagFormatter and displayed to the user. The enableReasoning toggle
    /// only controls whether /nothink instruction is sent, not whether thinking is hidden.
    private func getDisplayMessage(_ message: EnhancedMessage, enableReasoning: Bool) -> EnhancedMessage {
        /// Always return the original message - no filtering.
        return message
    }

    /// Build parent-child hierarchy map for tool messages Maps parent message ID → array of child messages.
    private func buildToolHierarchy(messages: [EnhancedMessage]) -> [UUID: [EnhancedMessage]] {
        var hierarchy: [UUID: [EnhancedMessage]] = [:]

        /// Find all child messages and map them to their parents.
        for message in messages {
            if let parentToolName = message.parentToolName, message.isToolMessage {
                /// Find the parent message by toolName.
                if let parent = messages.first(where: {
                    $0.toolName == parentToolName &&
                    $0.isToolMessage &&
                    $0.timestamp <= message.timestamp
                }) {
                    hierarchy[parent.id, default: []].append(message)
                }
            }
        }

        return hierarchy
    }

    // MARK: - Helper Methods

    /// Estimate token count for text using a simple approximation This provides reasonable estimates for performance tracking without requiring exact tokenization.
    private func estimateTokenCount(for text: String) -> Int {
        /// Simple estimation: ~1 token per 4 characters for English text This is a rough approximation commonly used for monitoring.
        let baseTokenCount = max(1, text.count / 4)

        /// Fast-path for very large texts: avoid expensive allocations and CharacterSet-based splitting on the main thread The stacktrace shows heavy CPU in `components(separatedBy:)` / `Substring._components` when large inputs hit UI paths.
        let largeThreshold = 5_000
        if text.count > largeThreshold {
            /// Add a modest buffer for word and special-char contributions without computing them exactly.
            return baseTokenCount + 100
        }

        /// For smaller texts (typical UI content), compute a more accurate estimate using lightweight splits.
        let wordCount = text.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }.count

        /// Count special (non-alphanumeric) characters by scanning bytes/Unicode scalars — cheaper than components with CharacterSet.
        var specialCharacters = 0
        for scalar in text.unicodeScalars {
            if !CharacterSet.alphanumerics.contains(scalar) {
                specialCharacters += 1
            }
        }

        /// Rough formula: base count + word boundary tokens + special character tokens.
        return baseTokenCount + (wordCount / 10) + (specialCharacters / 20)
    }

    // MARK: - Unified Conversation Processing

    /// Process conversation using AgentOrchestrator for identical behavior with API This ensures UI and external API use exactly the same conversation processing pipeline: - Same AgentOrchestrator with autonomous workflow support (maxIterations=100) - Same AI provider routing through EndpointManager - Same MCP tool injection and integration - Same memory and conversation management - Same streaming response handling.
    private func makeInternalAPIRequest(_ request: OpenAIChatRequest) async throws -> AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error> {
        logger.debug("AGENT_ORCHESTRATOR: Using AgentOrchestrator for autonomous workflow support")

        /// Get active conversation ID.
        guard let conversationId = activeConversation?.id else {
            throw NSError(domain: "ChatWidget", code: 1, userInfo: [NSLocalizedDescriptionKey: "No active conversation"])
        }

        /// Get user message content.
        guard let userMessage = request.messages.last(where: { $0.role == "user" && $0.content != nil }),
              let userContent = userMessage.content else {
            throw NSError(domain: "ChatWidget", code: 2, userInfo: [NSLocalizedDescriptionKey: "No user message with content"])
        }

        /// Get terminal manager for this conversation (if exists).
        let terminalManager = getTerminalManager()

        /// Create AgentOrchestrator instance (same as API).
        let orchestrator = AgentOrchestrator(
            endpointManager: endpointManager,
            conversationService: sharedConversationService,
            conversationManager: conversationManager,
            maxIterations: WorkflowConfiguration.defaultMaxIterations,
            terminalManager: terminalManager
        )

        /// Inject WorkflowSpawner into MCPManager for subagent support.
        conversationManager.mcpManager.setWorkflowSpawner(orchestrator)

        /// Connect performance monitor for metrics tracking.
        orchestrator.performanceMonitor = performanceMonitor

        /// Store orchestrator reference for cancellation support
        await MainActor.run {
            currentOrchestrator = orchestrator
        }

        /// Use streaming AgentOrchestrator (same as API streaming path).
        logger.debug("AGENT_ORCHESTRATOR: Starting streaming autonomous workflow for UI")

        /// FEATURE: Respect enableTools toggle - pass mcpToolsEnabled in samConfig.
        logger.debug("TOOLS_TOGGLE: enableTools=\(enableTools) - passing to samConfig")
        let samConfig = SAMConfig(
            sharedMemoryEnabled: nil,
            mcpToolsEnabled: enableTools,
            memoryCollectionId: nil,
            conversationTitle: nil,
            maxIterations: nil,
            enableReasoning: enableReasoning,
            workingDirectory: nil,
            systemPromptId: nil,
            isExternalAPICall: nil,
            loopDetectorConfig: nil,
            enableTerminalAccess: enableTerminalAccess,
            enableWorkflowMode: enableWorkflowMode,
            enableDynamicIterations: enableDynamicIterations
        )

        return try await orchestrator.runStreamingAutonomousWorkflow(
            conversationId: conversationId,
            initialMessage: userContent,
            model: request.model,
            samConfig: samConfig
        )
    }
}

// MARK: - UI Setup

struct MemoryItemView: View {
    let memory: ConversationMemory

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                /// Memory content type icon.
                Image(systemName: iconForContentType(memory.contentType))
                    .foregroundColor(colorForContentType(memory.contentType))
                    .font(.caption)

                /// Content preview.
                Text(memory.content)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundColor(.primary)

                Spacer()

                /// Similarity score.
                Text(String(format: "%.0f%%", memory.similarity * 100))
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            HStack {
                Text(memory.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Spacer()

                Text("\(memory.accessCount) accesses")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                if !memory.tags.isEmpty {
                    Text("• \(memory.tags.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func iconForContentType(_ type: ConversationEngine.MemoryContentType) -> String {
        switch type {
        case .message: return "message"
        case .userInput: return "person.crop.circle"
        case .assistantResponse: return "brain.head.profile"
        case .systemEvent: return "gear"
        case .toolResult: return "wrench.and.screwdriver"
        case .contextInfo: return "info.circle"
        case .document: return "doc.text"
        }
    }

    private func colorForContentType(_ type: ConversationEngine.MemoryContentType) -> Color {
        switch type {
        case .message: return .primary
        case .userInput: return .blue
        case .assistantResponse: return .green
        case .systemEvent: return .orange
        case .toolResult: return .purple
        case .contextInfo: return .secondary
        case .document: return .indigo
        }
    }
}

struct EnhancedMemoryItemView: View {
    let memory: ConversationMemory

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            /// Header with source badge
            HStack(spacing: 6) {
                sourceIcon

                Text(sourceLabel)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(sourceColor)

                Spacer()

                if memory.similarity > 0 && memory.similarity < 1.0 {
                    Text(String(format: "%.0f%%", memory.similarity * 100))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            /// Content
            Text(memory.content.prefix(200))
                .font(.caption)
                .foregroundColor(.primary)
                .lineLimit(3)

            /// Context from tags
            if !memory.tags.isEmpty {
                Text(memory.tags.first ?? "")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
        .padding(8)
        .background(sourceBackground)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(sourceColor.opacity(0.3), lineWidth: 1)
        )
    }

    private var sourceIcon: some View {
        Group {
            switch memory.contentType {
            case .message:
                if isFromActiveConversation {
                    Image(systemName: "message.fill")
                } else {
                    Image(systemName: "tray.full.fill")
                }
            case .contextInfo:
                Image(systemName: "archivebox.fill")
            default:
                Image(systemName: "tray.full.fill")
            }
        }
        .font(.caption2)
        .foregroundColor(sourceColor)
    }

    private var isFromActiveConversation: Bool {
        memory.tags.first?.contains("active conversation") ?? false
    }

    private var isFromArchive: Bool {
        memory.tags.first?.contains("archive") ?? false
    }

    private var sourceLabel: String {
        if isFromActiveConversation {
            return "ACTIVE"
        } else if isFromArchive {
            return "ARCHIVE"
        } else {
            return "STORED"
        }
    }

    private var sourceColor: Color {
        if isFromActiveConversation {
            return .blue
        } else if isFromArchive {
            return .orange
        } else {
            return .green
        }
    }

    private var sourceBackground: Color {
        sourceColor.opacity(0.05)
    }
}

// MARK: - Enhanced Message Bubble

struct EnhancedMessageBubble: View {
    let message: EnhancedMessage
    let enableAnimations: Bool
    @State private var showCopyConfirmation = false

    var body: some View {
        HStack(alignment: .top) {
            if message.isFromUser {
                Spacer(minLength: 60)
            }

            VStack(alignment: message.isFromUser ? .trailing : .leading, spacing: 8) {
                /// Reasoning content (for assistant messages only).
                if !message.isFromUser && message.hasReasoning {
                    ReasoningView(
                        reasoningContent: message.reasoningContent ?? "",
                        autoExpand: message.showReasoning
                    )
                }

                /// Enhanced message content with beautiful markdown support ONLY show message bubble if there's actual content.
                if !message.content.isEmpty {
                    HStack {
                        MarkdownText(message.content)
                            .id("markdown-\(message.id)")
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 18)
                                    .fill(message.isFromUser ?
                                          Color.accentColor :
                                          Color.primary.opacity(0.05))
                                    .shadow(
                                        color: .primary.opacity(0.1),
                                        radius: 2,
                                        x: 0,
                                        y: 1
                                    )
                            )
                            .foregroundColor(message.isFromUser ? .white : .primary)

                        /// Copy button.
                        Button(action: copyMessage) {
                            Image(systemName: showCopyConfirmation ? "checkmark" : "doc.on.doc")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                    .help("Copy message")
                    .opacity(0.7)
                }

                /// Timestamp and performance info ONLY show metadata if there's actual content.
                if !message.content.isEmpty {
                    HStack(spacing: 8) {
                        Text(message.timestamp, format: .dateTime.hour().minute().second())
                            .font(.caption2)
                            .foregroundColor(.secondary)

                    /// Performance metrics for AI responses.
                    if !message.isFromUser, let metrics = message.performanceMetrics {
                        /// More user-friendly formatting.
                        Text("• \(metrics.tokenCount) tokens • \(String(format: "%.1f", metrics.timeToFirstToken))s TTFT • \(String(format: "%.0f", metrics.tokensPerSecond)) tok/s")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .help("Token count • Time to First Token • Tokens per second")
                    } else if let processingTime = message.processingTime {
                        Text("• \(String(format: "%.1f", processingTime))s")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .help("Processing time")
                    }

                    if !message.isFromUser && message.hasReasoning {
                        Text("• reasoning")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .help("This message includes reasoning")
                    }
                    }
                }
            }

            if !message.isFromUser {
                Spacer(minLength: 60)
            }
        }
        .animation(enableAnimations ? .easeInOut(duration: 0.2) : nil, value: showCopyConfirmation)
    }

    private func copyMessage() {
        var copyContent = message.content

        /// Include reasoning content if available.
        if message.hasReasoning {
            copyContent = "Reasoning:\n\(message.reasoningContent ?? "")\n\nResponse:\n\(message.content)"
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyContent, forType: .string)

        showCopyConfirmation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            showCopyConfirmation = false
        }
    }
}

// MARK: - Processing Status

enum ProcessingStatus: Equatable {
    case loadingModel
    case thinking
    case processingTools(toolName: String)
    case generating
    case idle

    static func == (lhs: ProcessingStatus, rhs: ProcessingStatus) -> Bool {
        switch (lhs, rhs) {
        case (.loadingModel, .loadingModel),
             (.thinking, .thinking),
             (.generating, .generating),
             (.idle, .idle):
            return true

        case (.processingTools(let lhsName), .processingTools(let rhsName)):
            return lhsName == rhsName

        default:
            return false
        }
    }
}

// MARK: - UI Setup

private struct ProgressIndicatorView: View {
    let isProcessing: Bool
    let isAnyModelLoading: Bool
    let loadingModelName: String?
    private let logger = Logging.Logger(label: "com.sam.chat.indicator")

    var body: some View {
        Group {
            /// Log whenever this View body is evaluated.
            let _ = logger.debug("DEBUG: ProgressIndicatorView body evaluated - isAnyModelLoading=\(isAnyModelLoading), currentLoadingModelName=\(loadingModelName ?? "nil"), isProcessing=\(isProcessing)")

            if isAnyModelLoading, let modelName = loadingModelName {
                let _ = logger.debug("DEBUG: Showing ORANGE loading indicator for \(modelName)")
                /// Model is loading (highest priority).
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(.primary)
                    Text("Loading \(modelName)...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .onAppear {
                    logger.debug("MODEL_LOADING_UI: Orange loading indicator appeared for \(modelName)")
                }
            } else if isProcessing {
                /// Generic processing (inference, tool execution, etc.).
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Processing...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Tool Message with Nested Children

/// Renders a tool message with its nested child tool messages.
struct ToolMessageWithChildren: View {
    let message: EnhancedMessage
    let children: [EnhancedMessage]
    let enableAnimations: Bool
    let conversation: ConversationModel
    @Binding var messageToExport: EnhancedMessage?
    @State private var isExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            /// Parent tool card.
            MessageView(message: message, enableAnimations: enableAnimations, conversation: conversation, messageToExport: $messageToExport)

            /// Child tool cards (indented).
            if !children.isEmpty && isExpanded {
                VStack(spacing: 8) {
                    ForEach(children) { child in
                        MessageView(message: child, enableAnimations: enableAnimations, conversation: conversation, messageToExport: $messageToExport)
                            .padding(.leading, 30)
                    }
                }
                .padding(.top, 8)
            }
        }
    }
}
