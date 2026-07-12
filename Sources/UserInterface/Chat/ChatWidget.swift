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

/// ChatWidget with dynamic model loading, performance tracking, copy functionality, and chat management Includes chat duplication, JSON export, and session persistence features.
public struct ChatWidget: View {

    // MARK: - Prompt ID Constants
    // Extracted to help SwiftUI type-checker with the massive view body.
    static let samDefaultPromptId: UUID = {
        UUID(uuidString: "00[REDACTED]-0000-[REDACTED]00001") ?? UUID()
    }()
    static let samMinimalPromptId: UUID = {
        UUID(uuidString: "00[REDACTED]-0000-[REDACTED]00004") ?? UUID()
    }()
    @EnvironmentObject var endpointManager: EndpointManager
    let activeConversation: ConversationModel?
    @ObservedObject var messageBus: ConversationMessageBus
    @Binding var showingCustomInstructions: Bool
    let logger = Logging.Logger(label: "com.sam.chat")
    @EnvironmentObject var conversationManager: ConversationManager
    @EnvironmentObject var sharedConversationService: SharedConversationService

    @State var messageText = ""

    /// Dynamic height of the text input (auto-grows with content)
    @State var inputTextHeight: CGFloat = 45

    /// Track previous conversation for draft save/restore
    @State var previousConversationId: UUID?

    /// Debounced draft save task - prevents excessive disk writes while typing
    @State var draftSaveTask: Task<Void, Never>?

    /// Messages directly from MessageBus (single source of truth)
    /// MessageBus is @ObservedObject - SwiftUI automatically re-renders on @Published changes
    /// This is the CORRECT data flow: MessageBus → ChatWidget (not MessageBus → ConversationModel → ChatWidget)
    var messages: [EnhancedMessage] {
        messageBus.messages
    }

    @State var cachedToolHierarchy: [UUID: [EnhancedMessage]] = [:]

    /// PERFORMANCE: Cache cleaned messages to avoid regex operations on every render
    /// Key: message.id, Value: (contentHash, cleanedMessage)
    /// Only recompute cleanSpecialTokens when content actually changes
    @State var cachedCleanedMessages: [UUID: (contentHash: Int, cleaned: EnhancedMessage)] = [:]

    @State var processingStatus: ProcessingStatus = .idle
    @State var currentToolName: String?
    @State var isSending = false
    @State var streamingTask: Task<Void, Never>?

    /// Current orchestrator for cancellation support
    @State var currentOrchestrator: AgentOrchestrator?

    /// Input focus state for auto-focus on chat open.
    @FocusState var isInputFocused: Bool

    /// PERFORMANCE: Streaming update throttling.
    @State var pendingStreamingUpdate: (messageId: UUID, content: String)?
    @State var streamingUpdateTask: Task<Void, Never>?
    @State var lastUIUpdateTime: Date = Date()
    @State var streamingUpdateCount: Int = 0

    /// Scroll system: auto-scroll to latest content during streaming
    @State var lastScrollTime: Date = .distantPast
    @State var pendingScrollTask: Task<Void, Never>?
    @State var lastScrolledToId: UUID?

    /// Scroll proxy for keyboard navigation (stored from ScrollViewReader)
    @State var scrollProxy: ScrollViewProxy?

    /// Auto-scroll control: user explicitly enables/disables via toggle.
    /// Global and persistent across all conversations and app restarts.
    @AppStorage("scrollLockEnabled") var scrollLockEnabled: Bool = true

    /// Follow-output tracking: true when the user is "at the bottom" of the
    /// message list and auto-scroll should follow new content. Becomes false
    /// when the user scrolls up to read earlier messages so we stop yanking
    /// the viewport. Resumes via the "Jump to latest" pill.
    /// Decoupled from scrollLockEnabled (which is the user-set toggle) so
    /// the toggle can stay enabled while follow is temporarily paused.
    @State var isFollowingOutput: Bool = true

    /// Item currently visible at the bottom of the scroll viewport, tracked
    /// via `.scrollPosition(id:anchor:.bottom)`. When this matches the
    /// "scroll-bottom-anchor" sentinel, the user is at the bottom.
    @State var bottomVisibleItemId: String?

    /// User collaboration state.
    @State var isAwaitingUserInput = false
    @State var userCollaborationPrompt = ""
    @State var userCollaborationContext: String?
    @State var userCollaborationToolCallId: String?

    /// CRITICAL: Prevents conversation sync from overwriting streaming messages
    /// During active streaming, UI is source of truth - DO NOT load from conversation
    @State var isActivelyStreaming = false

    /// Thinking indicator for UI feedback.
    @State var isThinking = false
    @State var lastToolProcessorMessage = false
    @State var lastToolName: String?
    @State var lastToolExecutionId: String?

    /// Appearance preferences.
    @AppStorage("enableAnimations") var enableAnimations: Bool = true

    /// Flag to prevent syncSettingsToConversation during syncWithActiveConversation.
    @State var isLoadingConversationSettings = false

    /// Cached Copilot User API response for quota display
    /// Fetched on appear and refreshed periodically
    @State var cachedCopilotUserResponse: CopilotUserResponse?

    /// Flag to prevent bidirectional sync loop between UI and ConversationModel.
    @State var isSyncingMessages = false

    /// Combine subscription to observe conversation changes.
    @State var conversationSubscription: AnyCancellable?

    /// FEATURE: Enable/disable tool usage.
    @State var enableTools: Bool = true

    /// Shared data UI state
    @State var useSharedData: Bool = false
    @State var assignedSharedTopicId: String?
    @State var sharedTopics: [SharedTopic] = []
    let sharedTopicManager = SharedTopicManager()

    /// Configuration - dynamically loaded.
    @AppStorage("defaultModel") var appDefaultModel: String = "gpt-4"
    @State var selectedModel: String = "gpt-4"
    @State var temperature: Double = 0.7
    @State var topP: Double = 1.0
    @State var repetitionPenalty: Double?
    @State var maxTokens: Int? = 8192
    @State var maxMaxTokens: Int = 16384
    @State var contextWindowSize: Int = 4096
    @State var maxContextWindowSize: Int = 32768
    
    /// Model list management - using shared ModelListManager
    @ObservedObject var modelListManager = ModelListManager.shared
    
    @State var enableReasoning: Bool = false
    @State var thinkingEffort: String = "high"

    /// Local model loading state.
    @State var isLocalModelLoaded: Bool = false
    @State var isLoadingLocalModel: Bool = false

    /// Track if user manually overrode auto-disable tools for local models.
    @State var userManuallyEnabledTools: Bool = false

    /// Memory validation state.
    let localModelManager = LocalModelManager.shared
    @State var showMemoryWarning: Bool = false
    @State var memoryWarningMessage: String = ""
    @State var pendingModelLoad: (provider: String, model: String)?

    /// Advanced parameters toolbar - collapsible.
    @State var showAdvancedParameters = false

    /// Bottom bar popover states.
    @State var showingControlsPopover = false

    /// System prompt management - using systemPromptManager.selectedConfigurationId as single source of truth.
    @ObservedObject var systemPromptManager = SystemPromptManager.shared

    /// Chat session management.
    @StateObject var chatManager = ChatManager()
    @State var showingExportOptions = false

    /// Message export - centralized at ChatWidget level for reliable sheet presentation.
    @State var messageToExport: EnhancedMessage?

    /// Performance monitoring.
    @StateObject var performanceMonitor = PerformanceMonitor()
    @State var showingPerformanceMetrics = false

    /// Voice input/output management.
    @ObservedObject var voiceManager = VoiceManager.shared
    @StateObject var voiceBridge = VoiceChatBridge()
    @State var showVoiceAuthError = false
    @State var voiceAuthErrorMessage = ""
    
    /// API error notification
    @State var showAPIError = false
    @State var apiErrorMessage = ""
    
    /// Braille spinner busy indicator state
    @State var brailleSpinnerFrame = 0
    @State var busyStatusText: String = ""
    let brailleFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    /// Document import system for auto-importing attached files
    @State var documentImportSystem: DocumentImportSystem?

    /// Todo list manager (shared singleton)
    @ObservedObject var todoManager = TodoManager.shared
    let cachedFolderManager = FolderManager()

    /// Memory management - Session Intelligence.
    @State var showingMemoryPanel = false
    @State var memoryStatistics: ConversationEngine.MemoryStatistics?
    @State var archiveStatistics: MemoryMap?
    @State var contextStatistics: ContextStatistics?
    @State var conversationMemories: [ConversationMemory] = []
    @State var memorySearchQuery = ""
    @State var searchInStored = true
    @State var searchInActive = false
    @State var searchInArchive = false

    /// Working directory panel.
    @State var showingWorkingDirectoryPanel = false

    /// File attachments for current conversation.
    /// Files are copied to working directory and their paths stored here for context injection.
    @State var attachedFiles: [URL] = []

    /// Flag to prevent sending while files are being copied
    @State var isAttachingFiles: Bool = false

    /// Counter to prevent infinite retry loop in sendMessage attachment wait
    @State var attachmentRetryCount: Int = 0

    /// Agent todo list.
    @State var showingTodoListPopover = false
    /// Agent todo list - computed from TodoManager (reactive to changes)
    var agentTodoList: [AgentTodoItem] {
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

    public init(activeConversation: ConversationModel? = nil, messageBus: ConversationMessageBus, showingCustomInstructions: Binding<Bool>) {
        self.activeConversation = activeConversation
        self.messageBus = messageBus
        self._showingCustomInstructions = showingCustomInstructions
    }

    /// Check if input should be disabled (when model needs loading)
    var shouldDisableInput: Bool {
        return endpointManager.isLocalModel(selectedModel) && !isLocalModelLoaded
    }

    public var body: some View {
        Group {
            mainChatView
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
            .onChange(of: showingMemoryPanel) { _, newValue in
                savePanelState(panel: "memory", value: newValue)
                if newValue { loadMemoryStatistics() }
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

    /// Main content layout without modifiers
    var mainChatContent: some View {
        VStack(spacing: 0) {
            chatHeader
            Divider()
            messageList
            conditionalPanels
            Divider()
            messageInput
        }
    }

    var mainChatView: some View {
        mainChatContent
            .sheet(isPresented: $showingExportOptions) {
                exportChatDialog
            }
            .onAppear(perform: performMainChatViewAppear)
            .onChange(of: activeConversation?.id) { _, newID in
            handleConversationSwitch(newID)
        }
        .onChange(of: processingStatus) { oldValue, newValue in
            handleProcessingStatusChange(oldValue, newValue)
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
            handleModelChange(newValue)
        }
        .onChange(of: endpointManager.modelLoadingStatus) { _, newStatus in
            handleModelLoadingStatusChange(newStatus)
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
        .onChange(of: thinkingEffort) { _, _ in
            guard !isLoadingConversationSettings else { return }
            syncSettingsToConversation()
        }
        .onChange(of: enableTools) { oldValue, newValue in
            handleToolsChange(oldValue: oldValue, newValue: newValue)
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


    var memoryStatusSection: some View {
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

    var contextManagementSection: some View {
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
    func statBox(value: String, label: String) -> some View {
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

    var enhancedSearchSection: some View {
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



    /// Chat management functions moved to context menu or main menu bar.


    /// Scroll to the latest content with simple throttling.
    ///
    /// Strategy:
    /// - For growing content (streaming, tools, thinking): scroll to the last message
    /// Detected if current model is Z-Image (or Qwen-Image)

    /// - EDMDPMSolverMultistepScheduler produces garbage on MPS

    // MARK: - Bottom Bar Popovers

    /// Todo list popover content.
    var todoListPopoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent Tasks")
                .font(.headline)

            if agentTodoList.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        Text("No active tasks")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(agentTodoList) { item in
                            HStack(spacing: 6) {
                                Image(systemName: item.statusIcon)
                                    .font(.caption)
                                    .foregroundColor(todoStatusColor(item.status))
                                    .frame(width: 14)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title)
                                        .font(.caption)
                                        .lineLimit(1)
                                    if !item.description.isEmpty {
                                        Text(item.description)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .padding(12)
    }

    /// Color for todo status.
    func todoStatusColor(_ status: String) -> Color {
        switch status {
        case "completed": return .green
        case "in-progress": return .blue
        case "blocked": return .orange
        default: return .secondary
        }
    }

    /// Panels menu popover content.
    var controlsPopoverContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Controls")
                .font(.headline)
                .padding(.bottom, 4)

            /// Section: Panels
            sectionLabel("PANELS")
            panelToggleRow(icon: "folder", label: "Working Directory", isOn: $showingWorkingDirectoryPanel)
            panelToggleRow(icon: "brain.head.profile", label: "Session Intelligence", isOn: $showingMemoryPanel)
            panelToggleRow(icon: "chart.line.uptrend.xyaxis", label: "Performance Metrics", isOn: $showingPerformanceMetrics)

            Divider().padding(.vertical, 4)

            /// Section: Parameters
            sectionLabel("PARAMETERS")

            HStack(spacing: 8) {
                Text("Temperature")
                    .font(.caption)
                    .frame(width: 80, alignment: .leading)
                Slider(value: $temperature, in: 0.0...2.0, step: 0.1)
                    .frame(width: 100)
                Text("\(temperature, specifier: "%.1f")")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 30)
            }

            HStack(spacing: 8) {
                Text("Top-P")
                    .font(.caption)
                    .frame(width: 80, alignment: .leading)
                Slider(value: $topP, in: 0.0...1.0, step: 0.05)
                    .frame(width: 100)
                Text("\(topP, specifier: "%.2f")")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 30)
            }

            if let repPenalty = repetitionPenalty {
                HStack(spacing: 8) {
                    Text("Repetition")
                        .font(.caption)
                        .frame(width: 80, alignment: .leading)
                    Slider(value: Binding(
                        get: { repPenalty },
                        set: { repetitionPenalty = $0 }
                    ), in: 1.0...2.0, step: 0.1)
                        .frame(width: 100)
                    Text("\(repPenalty, specifier: "%.1f")")
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 30)
                    Button(action: { repetitionPenalty = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button(action: { repetitionPenalty = 1.1 }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle")
                            .font(.caption)
                        Text("Add Repetition Penalty")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Text("Max Tokens")
                    .font(.caption)
                    .frame(width: 80, alignment: .leading)
                let minTokens = 1024
                let effectiveMaxTokens = max(minTokens + 1024, maxMaxTokens)
                let clampedValue = min(max(minTokens, maxTokens ?? effectiveMaxTokens), effectiveMaxTokens)
                Slider(value: Binding(
                    get: { Double(clampedValue) },
                    set: { maxTokens = Int($0) }
                ), in: Double(minTokens)...Double(effectiveMaxTokens), step: 1024)
                    .frame(width: 100)
                Text(maxTokens != nil ? (maxTokens! >= 1024 ? "\(maxTokens!/1024)k" : "\(maxTokens!)") : "∞")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 30)
            }

            HStack(spacing: 8) {
                Text("Context")
                    .font(.caption)
                    .frame(width: 80, alignment: .leading)
                let minContext = 2048
                let effectiveMaxContext = max(minContext + 2048, maxContextWindowSize)
                let clampedContext = min(max(minContext, contextWindowSize), effectiveMaxContext)
                Slider(value: Binding(
                    get: { Double(clampedContext) },
                    set: { contextWindowSize = Int($0) }
                ), in: Double(minContext)...Double(effectiveMaxContext), step: 1024)
                    .frame(width: 100)
                Text("\(contextWindowSize/1024)k")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 30)
            }

            Divider().padding(.vertical, 4)

            /// Section: Features
            sectionLabel("FEATURES")

            Toggle(isOn: $enableReasoning) {
                Text("Reasoning")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if enableReasoning {
                Picker(selection: $thinkingEffort) {
                    ForEach(ThinkingEffort.allCases, id: \.rawValue) { effort in
                        Text(effort.displayName).tag(effort.rawValue)
                    }
                } label: {
                    Text("Thinking Effort")
                        .font(.caption)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
            }

            Toggle(isOn: $enableTools) {
                Text("Tools")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .onChange(of: enableTools) { _, newValue in
                guard !isLoadingConversationSettings else { return }
                if !newValue {
                }
                syncSettingsToConversation()
            }

            Divider().padding(.vertical, 4)

            /// Section: Shared Topic
            sectionLabel("SHARED TOPIC")

            Toggle(isOn: $useSharedData) {
                Text("Enable Shared Topic")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .onChange(of: useSharedData) { _, newValue in
                guard !isLoadingConversationSettings else { return }
                if newValue {
                    Task { await loadSharedTopics() }
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
            }

            if useSharedData {
                if sharedTopics.isEmpty {
                    Button(action: {
                        NotificationCenter.default.post(name: .showPreferences, object: nil)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.caption)
                            Text("No Topics - Create One")
                                .font(.caption)
                        }
                        .foregroundColor(.orange)
                    }
                    .buttonStyle(.plain)
                } else {
                    TopicPickerView(
                        selectedTopicId: $assignedSharedTopicId,
                        topics: sharedTopics
                    )
                    .onChange(of: assignedSharedTopicId) { _, newVal in
                        guard !isLoadingConversationSettings else { return }
                        if let topicId = newVal {
                            let topicName = sharedTopics.first(where: { $0.id == topicId })?.name
                            conversationManager.attachSharedTopic(topicId: UUID(uuidString: topicId), topicName: topicName)
                        }
                        syncSettingsToConversation()
                    }
                }
            }

            Divider().padding(.vertical, 4)

            /// Section: Actions
            sectionLabel("ACTIONS")

            Button(action: {
                showingControlsPopover = false
                showingExportOptions.toggle()
            }) {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 20)
                    Text("Export Chat")
                    Spacer()
                }
                .font(.caption)
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            }
            .buttonStyle(.borderless)

            Button(action: {
                scrollLockEnabled.toggle()
                if !isLoadingConversationSettings { syncSettingsToConversation() }
            }) {
                HStack {
                    Image(systemName: scrollLockEnabled ? "lock.fill" : "lock.open.fill")
                        .frame(width: 20)
                    Text(scrollLockEnabled ? "Scroll Lock: ON" : "Scroll Lock: OFF")
                    Spacer()
                    if scrollLockEnabled {
                        Image(systemName: "checkmark")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                    }
                }
                .font(.caption)
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
    }

    /// Section label helper.
    func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundColor(.secondary)
            .fontWeight(.semibold)
            .padding(.top, 2)
    }

    /// Helper for panel toggle rows in the panels menu.
    func panelToggleRow(icon: String, label: String, isOn: Binding<Bool>, disabled: Bool = false) -> some View {
        Button(action: { if !disabled { isOn.wrappedValue.toggle() } }) {
            HStack {
                Image(systemName: icon)
                    .frame(width: 20)
                Text(label)
                Spacer()
                if isOn.wrappedValue {
                    Image(systemName: "checkmark")
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                }
            }
            .font(.caption)
            .foregroundColor(disabled ? .secondary.opacity(0.5) : .primary)
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
    }

    // MARK: - Actions


    /// Handles conversation switch logic. Extracted from mainChatView to reduce
    /// SwiftUI type-checker load in the massive view body.
    func handleConversationSwitch(_ newID: UUID?) {
        /// FEATURE: Save draft message from previous conversation before switching
        if let prevId = previousConversationId,
           let prevConversation = conversationManager.conversations.first(where: { $0.id == prevId }) {
            if !messageText.isEmpty {
                prevConversation.settings.draftMessage = messageText
                logger.debug("DRAFT_SAVE: Saved draft (\(messageText.count) chars) to conversation \(prevId.uuidString.prefix(8))")
            }
            
            // Save performance metrics to previous conversation
            prevConversation.performanceMetrics = performanceMonitor.getMetricsForConversation()
            logger.debug("METRICS_SAVE: Saved \(prevConversation.performanceMetrics.count) metrics to conversation \(prevId.uuidString.prefix(8))")
            
            // Save immediately when switching (handles both draft and metrics)
            conversationManager.saveConversations()
        }

        /// Cancel any pending debounced draft save
        draftSaveTask?.cancel()
        draftSaveTask = nil

        /// Update previous conversation ID tracking
        previousConversationId = newID

        /// Log conversation switch
        if let conv = activeConversation {
            logger.debug("[CONVERSATION_OPENED] id=\(conv.id.uuidString.prefix(8)), title='\(conv.title)', messageCount=\(conv.messages.count)")

            /// FEATURE: Restore draft message from new conversation
            let draftMessage = conv.settings.draftMessage
            if !draftMessage.isEmpty {
                messageText = draftMessage
                logger.debug("DRAFT_RESTORE: Restored draft (\(draftMessage.count) chars) from conversation \(conv.id.uuidString.prefix(8))")
            } else {
                /// Clear input when switching to conversation with no draft
                messageText = ""
            }
            
            // Restore performance metrics from new conversation
            let metricsCount = conv.performanceMetrics.count
            performanceMonitor.loadMetricsFromConversation(conv.performanceMetrics)
            logger.debug("METRICS_RESTORE: Loaded \(metricsCount) metrics from conversation \(conv.id.uuidString.prefix(8))")
            
            // Set up callback to persist metrics when recorded
            // Uses weak reference to conversation to avoid capture issues
            let weakConversation = conv
            performanceMonitor.onMetricsRecorded = { [weak weakConversation] metrics in
                guard let conversation = weakConversation else { return }
                conversation.performanceMetrics.append(metrics)
                // Trim to 100 entries like PerformanceMonitor does
                if conversation.performanceMetrics.count > 100 {
                    conversation.performanceMetrics = Array(conversation.performanceMetrics.suffix(100))
                }
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
        conversationSubscription = nil

        syncWithActiveConversation()

        /// Scroll to the newest message after conversation switch.
        /// Delay lets SwiftUI complete the layout pass after sync.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let lastMessage = messages.last {
                scrollProxy?.scrollTo(lastMessage.id.uuidString, anchor: .bottom)
            }
            isInputFocused = true
        }
    }

    /// Extracted from mainChatView to reduce type-checker load.
    func handleProcessingStatusChange(_ oldValue: ProcessingStatus, _ newValue: ProcessingStatus) {
        /// Update braille spinner status text based on processing state.
        switch newValue {
        case .idle:
            busyStatusText = ""
        case .thinking:
            busyStatusText = "Thinking..."
        case .generating:
            if !busyStatusText.contains("Rate limited") {
                busyStatusText = "Generating..."
            }
        case .processingTools(let toolName):
            busyStatusText = "Running: \(toolName)"
        case .loadingModel:
            busyStatusText = "Loading model..."
        }

        /// Sync messages when processing completes
        if (oldValue == .thinking || oldValue == .generating) && newValue == .idle {
            logger.debug("MESSAGE_LIFECYCLE: Processing completed, triggering sync")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.syncWithActiveConversation()
            }
        }
    }

    /// Extracted from mainChatView to reduce type-checker load.
    func handleModelLoadingStatusChange(_ newStatus: [String: EndpointManager.ModelLoadingState]) {
        guard endpointManager.isLocalModel(selectedModel) else { return }

        if let status = newStatus[selectedModel] {
            switch status {
            case .loading(_):
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

    /// Extracted from mainChatView to reduce type-checker load.
    func handleToolsChange(oldValue: Bool, newValue: Bool) {
        guard !isLoadingConversationSettings else { return }

        if endpointManager.isLocalModel(selectedModel) && newValue && !oldValue {
            userManuallyEnabledTools = true
            logger.info("CHATWIDGET: User manually enabled tools for local model: \(selectedModel)")
        } else if !newValue {
            userManuallyEnabledTools = false
        }

        syncSettingsToConversation()
    }

    func performMainChatViewAppear() {
        SAMLog.chatViewAppear()
        
        // Initialize ModelListManager with dependencies
        modelListManager.initialize(endpointManager: endpointManager)
        
        // Initialize DocumentImportSystem for file attachments
        if documentImportSystem == nil {
            documentImportSystem = DocumentImportSystem(conversationManager: conversationManager)
        }
        
        // ModelListManager handles model loading automatically
        loadSystemPrompts()
        loadRecentChatSession()
        syncWithActiveConversation()

        /// Pre-fetch Copilot user info for quota display (non-blocking)
        Task {
            await refreshCopilotUserInfo()
        }

        /// Check if local model is already loaded on startup (Issue #1: input box disabled)
        Task {
            await loadSharedTopics()

            /// Check model loading status for current model
            if endpointManager.isLocalModel(selectedModel) {
                let loaded = await endpointManager.getModelLoadingStatus(selectedModel)
                await MainActor.run {
                    isLocalModelLoaded = loaded
                    logger.info("STARTUP: Local model \\(selectedModel) loaded status: \\(loaded)")
                }
            }

            /// Update max tokens/context from configuration (Issue #2: parameters not set)
            updateMaxContextForModel()
        }

        // If this ChatWidget is for a new conversation (no activeConversation),
        // initialize selectedModel from the global default set in preferences.
        if activeConversation == nil {
            selectedModel = appDefaultModel
        }

        /// Setup voice manager callbacks via bridge
        setupVoiceCallbacks()

        /// Model updates are now handled by ModelListManager automatically
        /// (listens to .endpointManagerDidUpdateModels, .aliceModelsLoaded)
        
        /// Listen for rate limit notifications - update braille spinner status bar.
        NotificationCenter.default.addObserver(
            forName: .providerRateLimitHit,
            object: nil,
            queue: .main
        ) { notification in
            guard let userInfo = notification.userInfo,
                  let retrySeconds = userInfo["retryAfterSeconds"] as? Double else {
                return
            }
            
            /// Update braille spinner status bar with retry countdown.
            busyStatusText = "Rate limited – retrying in \(Int(retrySeconds))s..."
        }
        
        /// Listen for rate limit retry
        NotificationCenter.default.addObserver(
            forName: .providerRateLimitRetrying,
            object: nil,
            queue: .main
        ) { _ in
            busyStatusText = "Generating..."
        }

        /// Auto-focus input box when chat opens.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isInputFocused = true
        }

        /// Sync messages on initial view appearance.
        /// onChange(of: activeConversation?.id) doesn't fire if conversation is already set before view loads.
        syncWithActiveConversation()

        /// Scroll to newest message on initial appearance
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let lastMessage = messages.last {
                scrollProxy?.scrollTo(lastMessage.id.uuidString, anchor: .bottom)
            }
            isInputFocused = true
        }

        /// FEATURE: Restore draft message on initial appearance
        /// This handles the case where conversation is already set before view loads
        if let conversation = activeConversation {
            let draftMessage = conversation.settings.draftMessage
            if !draftMessage.isEmpty {
                messageText = draftMessage
                logger.debug("DRAFT_RESTORE: Restored draft on appear (\(draftMessage.count) chars) from conversation \(conversation.id.uuidString.prefix(8))")
            }

            // Restore performance metrics on initial appearance
            performanceMonitor.loadMetricsFromConversation(conversation.performanceMetrics)
            logger.debug("METRICS_RESTORE_APPEAR: Loaded \(conversation.performanceMetrics.count) metrics from conversation \(conversation.id.uuidString.prefix(8))")

            // Set up callback to persist metrics when recorded
            let weakConversation = conversation
            performanceMonitor.onMetricsRecorded = { [weak weakConversation] metrics in
                guard let conv = weakConversation else { return }
                conv.performanceMetrics.append(metrics)
                if conv.performanceMetrics.count > 100 {
                    conv.performanceMetrics = Array(conv.performanceMetrics.suffix(100))
                }
            }

            /// Track this conversation as previous for future switches
            previousConversationId = conversation.id
        }
    }

    func syncWithActiveConversation() {
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

        /// Reset flags after a delay to ensure onChange handlers that fire asynchronously
        /// still see the loading flag. defer runs before onChange handlers execute.
        defer {
            DispatchQueue.main.async {
                isLoadingConversationSettings = false
                isSyncingMessages = false
                logger.debug("MESSAGE_LIFECYCLE: syncWithActiveConversation - END (flags cleared)")
            }
        }

        /// REMOVED: Message syncing - messages is now computed property reading activeConversation?.messages
        /// ConversationModel.messages auto-syncs FROM MessageBus via subscription
        /// ChatWidget always reads latest messages via computed property

        // Sync shared data settings into UI state
        useSharedData = conversation.settings.useSharedData
        assignedSharedTopicId = conversation.settings.sharedTopicId?.uuidString

        // Sync panel visibility states from conversation settings
        showingMemoryPanel = conversation.settings.showingMemoryPanel
        showingWorkingDirectoryPanel = conversation.settings.showingWorkingDirectoryPanel
        showAdvancedParameters = conversation.settings.showAdvancedParameters
        showingPerformanceMetrics = conversation.settings.showingPerformanceMetrics

        logger.debug("PANEL_SYNC: Loaded panel states - memory:\(showingMemoryPanel) workdir:\(showingWorkingDirectoryPanel) advanced:\(showAdvancedParameters) perf:\(showingPerformanceMetrics)")

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
        thinkingEffort = conversation.settings.thinkingEffort
        enableTools = conversation.settings.enableTools
        /// scrollLockEnabled is now global (@AppStorage), not per-conversation

        /// Z-Image models now work on MPS with bfloat16 (2x faster than CPU)
        /// No automatic device switching needed on restore

        /// Auto-adjust guidance scale for Z-Image models if out of range

        /// Auto-validate image size for Z-Image models on restore

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


    /// Handles model selection changes. Extracted from view body to avoid
    /// SwiftUI type-checker timeout in the massive ChatWidget.
    func handleModelChange(_ newValue: String) {
        guard !isLoadingConversationSettings else { return }

        if let activeConv = conversationManager.activeConversation {
            let samDefaultId = Self.samDefaultPromptId
            let samMinimalId = Self.samMinimalPromptId
            let currentPromptId = activeConv.settings.selectedSystemPromptId ?? samDefaultId

            if currentPromptId == samDefaultId || currentPromptId == samMinimalId {
                let isLocalModel = newValue.lowercased().contains("gguf") ||
                                  newValue.lowercased().contains("mlx") ||
                                  newValue.lowercased().contains("local-llama")

                var updatedConv = activeConv
                let targetPromptId = isLocalModel ? samMinimalId : samDefaultId

                if currentPromptId != targetPromptId {
                    updatedConv.settings.selectedSystemPromptId = targetPromptId
                    logger.info("Auto-selected prompt for \(newValue)")
                    conversationManager.activeConversation = updatedConv
                    conversationManager.saveConversations()
                    systemPromptManager.selectedConfigurationId = targetPromptId
                }
            }
        }

        updateMaxContextForModel()
        preloadModel()

        Task {
            if endpointManager.isLocalModel(newValue) {
                let loaded = await endpointManager.getModelLoadingStatus(newValue)
                await MainActor.run {
                    isLocalModelLoaded = loaded
                }
            } else {
                await MainActor.run {
                    isLocalModelLoaded = false
                    userManuallyEnabledTools = false
                }
            }
        }
    }
    func updateMaxContextForModel() {
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

    func preloadModel() {
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

    func syncSettingsToConversation() {
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
        conversation.settings.thinkingEffort = thinkingEffort
        conversation.settings.enableTools = enableTools
        /// scrollLockEnabled is now global (@AppStorage), not per-conversation
        conversation.settings.useSharedData = useSharedData
        conversation.settings.sharedTopicId = assignedSharedTopicId.flatMap { UUID(uuidString: $0) }
        conversation.settings.sharedTopicName = assignedSharedTopicId.flatMap { id in sharedTopics.first(where: { $0.id == id })?.name }

        /// Sync panel visibility states to conversation
        conversation.settings.showingMemoryPanel = showingMemoryPanel
        conversation.settings.showingWorkingDirectoryPanel = showingWorkingDirectoryPanel
        conversation.settings.showAdvancedParameters = showAdvancedParameters
        conversation.settings.showingPerformanceMetrics = showingPerformanceMetrics

        conversation.updated = Date()

        /// Save conversations to disk after updating settings.
        conversationManager.saveConversations()
    }

    /// Save panel visibility state to conversation settings
    func savePanelState(panel: String, value: Bool) {
        logger.debug("PANEL_CHANGE: \(panel) panel changed to \(value), isLoading=\(isLoadingConversationSettings), hasConv=\(activeConversation != nil)")

        guard let conversation = activeConversation, !isLoadingConversationSettings else {
            logger.debug("PANEL_BLOCKED: \(panel) panel save blocked - isLoading=\(isLoadingConversationSettings), hasConv=\(activeConversation != nil)")
            return
        }

        switch panel {
        case "memory":
            conversation.settings.showingMemoryPanel = value
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
    func loadLocalModel() {
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
            modelName: modelName
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
    func performModelLoad() {
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
    func ejectLocalModel() {
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

    func sendMessage() {
        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isSending else { return }

        /// Re-enable follow-output when the user sends a message. Otherwise
        /// if the user has scrolled up to read earlier content the new
        /// response (which they explicitly asked for) wouldn't auto-scroll
        /// and they'd have to manually click "Jump to latest".
        isFollowingOutput = true

        /// RACE CONDITION FIX: Wait if files are still being copied
        /// This prevents the agent from trying to import files before the copy completes
        if isAttachingFiles {
            attachmentRetryCount += 1
            if attachmentRetryCount >= 30 {
                logger.error("Attachment wait timed out after \(attachmentRetryCount) retries (3 seconds) - sending anyway")
                /// Reset and continue with message
                attachmentRetryCount = 0
                isAttachingFiles = false
                // Fall through to send
            }
            if isAttachingFiles {
                logger.warning("Send blocked - waiting for file attachments to complete")
                /// Schedule retry after a brief delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
                    self.sendMessage()
                }
                return
            }
        }
        
        /// Reset attachment retry counter on successful send entry
        attachmentRetryCount = 0

        let originalText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        var textForAPI = originalText
        var injectedContexts: [String] = []

        /// FEATURE: Inject custom instructions into FIRST user message only (per-conversation).
        /// Mini-prompts are persistent instructions that should be set once at conversation start,
        /// not repeated in every user message (which would waste context and cause issues).
        if let activeConversation = activeConversation {
            /// CRITICAL: Check MessageBus directly (not conversation.messages) for accurate count
            /// conversation.messages may be stale due to sync delays
            let currentUserMessageCount = messageBus.messages.filter { $0.isFromUser }.count
            let isFirstUserMessage = currentUserMessageCount == 0
            
            if isFirstUserMessage {
                logger.debug("CUSTOM_INSTRUCTION_TRACE: ChatWidget first message check - convId=\(activeConversation.id.uuidString.prefix(8)), enabledCount=\(activeConversation.enabledCustomInstructionIds.count)")
                let customInstructionText = CustomInstructionManager.shared.getInjectedText(
                    for: activeConversation.id,
                    enabledIds: activeConversation.enabledCustomInstructionIds
                )
                if !customInstructionText.isEmpty {
                    injectedContexts.append(customInstructionText)
                    let enabledPrompts = CustomInstructionManager.shared.enabledInstructions(
                        for: activeConversation.id,
                        enabledIds: activeConversation.enabledCustomInstructionIds
                    )
                    /// ChatWidget handles first-message persist only. AgentOrchestrator handles
                    /// one-time mid-conversation persist and ephemeral per-turn injection.
                    logger.info("CUSTOM_INSTRUCTION_TRACE: ChatWidget injected \(enabledPrompts.count) custom instruction(s) into FIRST user message: \(enabledPrompts.map { $0.name }.joined(separator: ", "))")
                } else {
                    logger.debug("CUSTOM_INSTRUCTION_TRACE: ChatWidget customInstructionText was empty")
                }
            } else {
                logger.debug("CUSTOM_INSTRUCTION_TRACE: ChatWidget skipped injection (not first message, count=\(currentUserMessageCount), enabledCount=\(activeConversation.enabledCustomInstructionIds.count))")
            }
        }

        /// FEATURE: Inject userContext block for KV cache stability.
        /// Contains date/time, user info, location, and coordinates.
        /// Conversation ID, tools, working directory, LTM, and session naming are handled
        /// by the orchestrator's dynamic context injection (separate <userContext> block).
        let coordinates = LocationManager.shared.getEffectiveCoordinates()
        let userContext = SystemPromptConfiguration.buildUserContextBlock(
            conversationId: nil,
            location: LocationManager.shared.getEffectiveLocation(),
            latitude: coordinates?.latitude,
            longitude: coordinates?.longitude
        )
        injectedContexts.append(userContext)

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
            busyStatusText = "Generating..."
            
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
            
            /// Update StateManager for the attachment flow
            conversationManager.stateManager.updateState(conversationId: conversation.id) { state in
                state.status = .processing(toolName: "Document Import")
            }
            
            /// Import files with tool card updates
            /// CRITICAL: Assign to streamingTask so the stop button can cancel it
            streamingTask = Task { @MainActor in
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
                    streamingTask = nil
                    currentOrchestrator = nil
                    
                    /// Update StateManager: Mark as idle
                    if let conv = activeConversation {
                        conv.isProcessing = false
                        conversationManager.stateManager.updateState(conversationId: conv.id) { state in
                            state.status = .idle
                            state.activeTools.removeAll()
                        }
                    }
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

        messageText = ""
        /// Clear draft when message is sent
        if let conversation = activeConversation {
            conversation.settings.draftMessage = ""
        }

        /// Prevent multiple sends.
        isSending = true

        /// Sync with conversation-level state for persistence across conversation switches
        if let conversation = activeConversation {
            conversation.isProcessing = true

            /// Update StateManager (Task 18): Track processing state
            conversationManager.stateManager.updateState(conversationId: conversation.id) { state in
                state.status = .processing(toolName: nil)
            }
            logger.debug("Updated StateManager: conversation \(conversation.id) now processing")
        }

        /// Reset scroll-away state when user sends a message - they expect to follow the response
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
    func submitUserResponse() {
        guard let toolCallId = userCollaborationToolCallId,
              let conversationId = activeConversation?.id else {
            logger.error("Cannot submit user response - missing toolCallId=\(userCollaborationToolCallId ?? "nil") conversationId=\(activeConversation?.id.uuidString ?? "nil")")
            return
        }

        let userInput = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userInput.isEmpty else { return }

        /// Resume follow-output so the agent's response scrolls into view.
        isFollowingOutput = true

        logger.info("USER_COLLAB: Submitting user response for collaboration tool call: \(toolCallId)")

        /// Clear message text immediately for UX responsiveness.
        messageText = ""

        /// Direct call - tool runs in-process, no HTTP roundtrip needed.
        /// This eliminates network failures, @MainActor contention with Vapor,
        /// and auth middleware as potential failure points.
        let success = UserCollaborationTool.submitUserResponse(
            toolCallId: toolCallId,
            userInput: userInput
        )

        if success {
            logger.info("USER_COLLAB: Response submitted directly to tool")

            /// Clear collaboration state
            isAwaitingUserInput = false
            userCollaborationPrompt = ""
            userCollaborationContext = nil
            userCollaborationToolCallId = nil
        } else {
            logger.error("USER_COLLAB: Direct submission failed - toolCallId not found in pending responses")
            /// Restore input so user can retry
            messageText = userInput
        }
    }

    /// Parse SSE event from streaming chunk Handles three event types: - [SAM_EVENT:user_input_required] - Requests user input during tool execution - [SAM_EVENT:agent_status_update] - Shows agent workflow status (CONTINUE, WORK_COMPLETE) - [SAM_EVENT:image_display] - Displays generated images in chat.
    func parseSSEEvent(from content: String) -> Bool {
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
            /// Add agent's collaboration prompt as a visible message in the chat
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
    func playCompletionSound() {
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
    func setupVoiceCallbacks() {
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
    func completeAllRunningTools() {
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
    func updateStreamingMessage(messageId: UUID, content: String) async {
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

    func processMessage(text: String) async {
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

        /// Add user message with performance tracking Store the FULL message (with custom instructions) for API/memory, display filtered version in UI.
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
                /// NOTE: AgentOrchestrator already persisted the message to MessageBus when it received
                /// the tool-response API call. We just need to display the streaming chunk, not re-add it.
                if chunk.choices.first?.delta.role == "user",
                   let content = chunk.choices.first?.delta.content, !content.isEmpty {
                    logger.info("USER_COLLAB: Received user message chunk (already persisted by AgentOrchestrator)", metadata: [
                        "content": .string(content)
                    ])
                    /// Continue processing - chunk will be appended to accumulated response for display
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

                    /// Only finalize if still streaming (orchestrator may have already completed it)
                    /// Calling completeStreamingMessage twice causes double layout disruption
                    let currentMessage = messages[index]
                    if currentMessage.isStreaming {
                        activeConversation?.messageBus?.completeStreamingMessage(
                            id: msgId,
                            performanceMetrics: messageMetrics,
                            processingTime: processingTime
                        )
                    } else if messageMetrics != nil {
                        /// Message already completed by orchestrator - just add metrics
                        activeConversation?.messageBus?.updateMessage(
                            id: msgId,
                            performanceMetrics: messageMetrics,
                            processingTime: processingTime
                        )
                    }

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

    func getRecentMessages(limit: Int, excludingId: UUID?) -> [Message] {
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

    func retrieveMemoryContext(query: String, conversationId: String?) async -> String {
        /// Use ConversationManager's memory context method (SAM 1.0 style).
        guard let conversation = activeConversation else {
            return ""
        }

        return await conversationManager.getMemoryContext(for: query, conversationId: conversation.id)
    }

    func enhanceSystemPromptWithMemory(originalPrompt: String, memoryContext: String, recentMessages: [Message]) -> String {
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
    /// Load shared topics list from SharedTopicManager
    func loadSharedTopics() async {
        do {
            let list = try sharedTopicManager.listTopics()
            await MainActor.run {
                sharedTopics = list

                /// Heal stale topic references after deduplication migration
                /// If conversation points to a topic ID that no longer exists, but the name matches
                /// an existing topic, reassign to the correct one.
                if let currentTopicId = assignedSharedTopicId,
                   !list.contains(where: { $0.id == currentTopicId }),
                   let topicName = conversationManager.activeConversation?.settings.sharedTopicName,
                   let matchingTopic = list.first(where: { $0.name == topicName }) {
                    logger.info("Healing stale topic reference: \(currentTopicId) -> \(matchingTopic.id) for topic '\(topicName)'")
                    assignedSharedTopicId = matchingTopic.id
                    conversationManager.attachSharedTopic(topicId: UUID(uuidString: matchingTopic.id), topicName: matchingTopic.name)
                }
            }
        } catch {
            logger.error("Failed to load shared topics: \(error)")
        }
    }

    /// Beautify model name: "gpt-4.1" -> "GPT-4.1", "claude-sonnet-4.5" -> "Claude Sonnet 4.5"
    func beautifyModelName(_ modelId: String) -> String {
        /// Remove version dates
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
    func beautifyProviderName(_ provider: String) -> String {
        let providerMap: [String: String] = [
            "github_copilot": "GitHub Copilot",
            "openai": "OpenAI",
            "deepseek": "DeepSeek",
            "local": "Local",
            "mlx": "MLX"
        ]
        return providerMap[provider.lowercased()] ?? provider.capitalized
    }

    /// Format multiplier to avoid unnecessary decimals
    /// Load global MLX settings from preferences.
    func loadGlobalMLXSettings() {
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

    /// Load global llama.cpp settings from preferences. Mirror of
    /// loadGlobalMLXSettings so the log line at chat-start names the
    /// active llama preset and its topK/minP.
    func loadGlobalLlamaSettings() {
        let llamaConfig = getGlobalLlamaConfiguration()
        logger.debug("Loaded global llama settings: nCtx=\(llamaConfig.nCtx) topP=\(llamaConfig.topP) temp=\(llamaConfig.temperature) repPenalty=\(llamaConfig.repetitionPenalty) topK=\(llamaConfig.topK) minP=\(llamaConfig.minP)")
    }

    /// Load system prompts - Ensure SystemPromptManager is initialized with default.
    func loadSystemPrompts() {
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
    func saveCurrentChatSession() {
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
    func loadRecentChatSession() {
        if let currentSession = chatManager.currentSession {
            loadChatSession(currentSession)
        }
    }

    func loadChatSession(_ session: ChatSession) {
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

    var exportChatDialog: some View {
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

    func loadMemoryStatistics() {
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

    func formatTokenCount(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000.0)
        }
        return "\(count)"
    }

    func performEnhancedSearch() {
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

    func clearConversationMemories() {
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

    /// Calculate text input height based on content for auto-growing input field.
    func recalculateInputHeight(for text: String) {
        let minHeight: CGFloat = 45
        let maxHeight: CGFloat = 200
        let lineHeight: CGFloat = 20

        if text.isEmpty {
            inputTextHeight = minHeight
            return
        }

        let lineCount = CGFloat(text.components(separatedBy: "\n").count)
        // Account for TextEditor padding (top + bottom ~12px)
        let calculated = (lineCount * lineHeight) + 12
        inputTextHeight = max(minHeight, min(calculated, maxHeight))
    }

    /// Context menu for conversation title in header (matches sidebar menu)
    @ViewBuilder
    func conversationHeaderContextMenu(_ conversation: ConversationModel) -> some View {
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

            /// Use shared FolderManager from environment instead of creating new instance on every render.
            /// Creating FolderManager() in a view body causes 800+ disk reads per session.
            /// Reuse a single cached FolderManager instead of creating one per render.
            /// The Menu body re-evaluates on every render pass, so FolderManager() was being
            /// called hundreds of times, each hitting disk.
            if !cachedFolderManager.folders.isEmpty {
                Divider()
                ForEach(cachedFolderManager.folders, id: \.id) { folder in
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
    func calculateMessageImportance(text: String, isUser: Bool) -> Double {
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
    func attachFiles() {
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
    func clearAttachedFiles() {
        attachedFiles.removeAll()
        logger.info("Cleared all attached files")
    }

    func selectWorkingDirectory() {
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

    func revealWorkingDirectoryInFinder() {
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

    func resetWorkingDirectoryToDefault() {
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

    func exportChatAsJSON() {
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

    func exportChatAsText() {
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
    func exportChatAsPDF() {
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
    func getCachedCleanedMessage(_ message: EnhancedMessage) -> EnhancedMessage {
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

    func createCleanedMessage(_ message: EnhancedMessage) -> EnhancedMessage {
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
    func extractToolMetadata(from content: String) -> (String?, ToolStatus?, String?, [String]?) {
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
    func isSystemStatusMessage(_ content: String) -> Bool {
        let systemPatterns = [
            "Model loaded",
            "Loading model",
            "Session restored",
            "Configuration updated"
        ]

        return systemPatterns.contains { content.contains($0) }
    }

    /// Clean special tokens and tool XML from accumulated message content Filters tokens that may leak through due to token-by-token streaming fragmentation Applied only at message finalization to minimize false positive risk.
    func cleanSpecialTokens(from content: String, isToolMessage: Bool = false) -> String {
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

        /// Remove <think>...</think> blocks (and any orphaned tags).
        /// Some providers (MiniMax M2.x) emit reasoning inline as <think> tags.
        /// The provider-side streaming parser usually strips these, but if a tag
        /// arrives split across a chunk boundary the parser can miss it - this
        /// is the safety net. Pattern uses [\\s\\S] instead of . because NSRegularExpression
        /// doesn't match newlines without the dotMatchesLineSeparators flag.
        if let thinkBlockPattern = try? NSRegularExpression(
            pattern: "<think>[\\s\\S]*?</think>\\n*",
            options: []
        ) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = thinkBlockPattern.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: range,
                withTemplate: ""
            )
        }
        cleaned = cleaned.replacingOccurrences(of: "<think>", with: "", options: .literal)
        cleaned = cleaned.replacingOccurrences(of: "</think>", with: "", options: .literal)

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
    func filterInternalMarkersNoTrim(from input: String) -> String {
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

            /// Filter session naming markers (auto-naming feature)
            if trimmed.contains("<!--session:") && trimmed.contains("-->") {
                continue
            }

            /// Default: keep the original raw line (preserve leading/trailing spaces on line).
            outputLines.append(raw)
        }

        /// Rejoin using \n to preserve original paragraph breaks.
        return outputLines.joined(separator: "\n")
    }

    /// Extract tool name from tool execution message Format: "SUCCESS: - Using memory_search..." → "memory_search".
    func extractToolName(from content: String) -> String? {
        /// Pattern: "SUCCESS: - Using [toolname]...".
        if let range = content.range(of: "Using ", options: .caseInsensitive),
           let endRange = content[range.upperBound...].range(of: "...") {
            let toolName = String(content[range.upperBound..<endRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            return toolName.isEmpty ? nil : toolName
        }
        return nil
    }

    // MARK: - UI Setup

    /// Calculate dynamic width for model dropdown based on longest model name Ensures all model names are fully visible without truncation.
    var modelDropdownWidth: CGFloat {
        /// Calculate width needed for longest model name Rough estimate: 8 points per character + 40 points for picker chrome.
        let longestModelName = modelListManager.availableModels.max(by: { $0.count < $1.count }) ?? ""
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
    func updateMessageContent(messageId: UUID, newContent: String, isComplete: Bool = false) {
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
    func updateMessageMetadata(messageId: UUID, metadata: [String: String], toolStatus: String?) {
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

    /// Refresh Copilot user info from the User API for quota display
    /// Non-blocking, updates cachedCopilotUserResponse state
    func refreshCopilotUserInfo() async {
        do {
            let token = try await CopilotTokenStore.shared.getCopilotToken()
            let userResponse = try await CopilotUserAPIClient.shared.fetchUser(token: token)
            await MainActor.run {
                cachedCopilotUserResponse = userResponse
            }
            if let login = userResponse.login {
                logger.debug("Fetched Copilot user info for: \(login)")
            }
        } catch {
            // Non-fatal - fall back to header-based quota display
            logger.debug("Could not fetch Copilot user info: \(error.localizedDescription)")
        }
    }

    /// Check if message is a tool call JSON message.
    func isToolCallJSONMessage(_ message: EnhancedMessage) -> Bool {
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
    func getDisplayMessage(_ message: EnhancedMessage, enableReasoning: Bool) -> EnhancedMessage {
        /// Always return the original message - no filtering.
        return message
    }

    /// Build parent-child hierarchy map for tool messages Maps parent message ID → array of child messages.
    func buildToolHierarchy(messages: [EnhancedMessage]) -> [UUID: [EnhancedMessage]] {
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
    func estimateTokenCount(for text: String) -> Int {
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
    func makeInternalAPIRequest(_ request: OpenAIChatRequest) async throws -> AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error> {
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

        /// Create AgentOrchestrator instance (same as API).
        let orchestrator = AgentOrchestrator(
            endpointManager: endpointManager,
            conversationService: sharedConversationService,
            conversationManager: conversationManager,
            maxIterations: WorkflowConfiguration.defaultMaxIterations,
        )

        /// Connect performance monitor for metrics tracking.
        orchestrator.performanceMonitor = performanceMonitor
        
        // Note: onMetricsRecorded callback is set up in conversation switch handler
        // to ensure it stays in sync with the current conversation

        /// Store orchestrator reference for cancellation support
        await MainActor.run {
            currentOrchestrator = orchestrator
        }

        /// Use streaming AgentOrchestrator (same as API streaming path).
        logger.debug("AGENT_ORCHESTRATOR: Starting streaming autonomous workflow for UI")

        /// FEATURE: Respect enableTools toggle - pass mcpToolsEnabled in samConfig.
        /// FEATURE: Respect thinkingEffort - pass ThinkingConfig with effort level.
        logger.debug("TOOLS_TOGGLE: enableTools=\(enableTools) - passing to samConfig")
        let thinkingConfig = ThinkingConfig(
            mode: enableReasoning ? "enabled" : "disabled",
            effort: thinkingEffort
        )
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
            thinking: thinkingConfig
        )

        return try await orchestrator.runStreamingAutonomousWorkflow(
            conversationId: conversationId,
            initialMessage: userContent,
            model: request.model,
            samConfig: samConfig
        )
    }
}
