// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import ConfigurationSystem
import Combine

// MARK: - Default Model Selection

/// Helper to determine the default model based on UserDefaults.
/// Note: We can't check LocalModelManager here due to circular dependencies.
/// The empty default ensures users select a model if none is configured.
public func getDefaultModel() -> String {
    /// Check UserDefaults first for explicit override
    if let userDefault = UserDefaults.standard.string(forKey: "defaultModel"), !userDefault.isEmpty {
        return userDefault
    }
    
    /// Return empty string to force user selection
    /// This prevents the error where gpt-4 is selected but no API key is configured
    /// The onboarding wizard will guide users to configure a model/provider
    return ""
}

// MARK: - Conversation Telemetry

/// Tracks intelligence system usage statistics for Session Intelligence UI.
/// Provides visibility into memory, archive, and context operations.
public struct ConversationTelemetry: Codable, Sendable {
    /// Archive recalls - how many times agent fetched from archived context
    public var archiveRecallCount: Int = 0
    
    /// Memory retrievals - how many times agent searched stored memories
    public var memoryRetrievalCount: Int = 0
    
    /// YaRN compression events - how many times context was compressed
    public var compressionEventCount: Int = 0
    
    /// Context window overflow events - how many times we hit token limits
    public var contextOverflowCount: Int = 0
    
    /// Last telemetry update timestamp
    public var lastUpdated: Date = Date()
    
    public init() {}
    
    /// Reset all counters (for testing or user request)
    public mutating func reset() {
        archiveRecallCount = 0
        memoryRetrievalCount = 0
        compressionEventCount = 0
        contextOverflowCount = 0
        lastUpdated = Date()
    }
}

// MARK: - Conversation Settings

public struct ConversationSettings: Codable, Sendable {
    public var selectedModel: String
    public var temperature: Double
    public var topP: Double
    public var maxTokens: Int?
    public var contextWindowSize: Int
    public var selectedSystemPromptId: UUID?
    public var workspacePromptIds: [UUID]
    public var selectedPersonalityId: UUID?
    public var enableReasoning: Bool
    public var enableTools: Bool
    public var autoApprove: Bool
    public var enableTerminalAccess: Bool
    public var enableWorkflowMode: Bool
    public var enableDynamicIterations: Bool
    public var scrollLockEnabled: Bool
    /// Shared data settings
    public var useSharedData: Bool
    public var sharedTopicId: UUID?
    public var sharedTopicName: String?
    /// Draft message - unsent text in input box (persisted per conversation)
    public var draftMessage: String
    /// Stable Diffusion parameters
    public var sdNegativePrompt: String
    public var sdSteps: Int
    public var sdGuidanceScale: Float
    public var sdScheduler: String
    public var sdSeed: Int
    public var sdUseKarras: Bool  /// Karras sigma schedule for DPM++
    public var sdImageCount: Int  /// Number of images to generate (1-10)
    public var sdImageWidth: Int  /// Image width in pixels
    public var sdImageHeight: Int  /// Image height in pixels
    public var sdEngine: String  /// "coreml" or "python"
    public var sdDevice: String  /// Compute device for Python engine ("auto", "mps", "cpu")
    public var sdUpscaleModel: String  /// "none", "general", "anime", "general_x2"
    /// Image-to-Image parameters
    public var sdStrength: Double  /// Denoising strength (0.0-1.0): 0.0=no change, 1.0=full generation
    public var sdInputImagePath: String?  /// Path to input image for img2img
    /// UI panel visibility states
    public var showingMemoryPanel: Bool
    public var showingTerminalPanel: Bool
    public var showingWorkingDirectoryPanel: Bool
    public var showAdvancedParameters: Bool
    public var showingPerformanceMetrics: Bool
    
    /// Telemetry for Session Intelligence UI - tracks memory/archive/compression usage
    public var telemetry: ConversationTelemetry

    public init(
        selectedModel: String = getDefaultModel(),
        temperature: Double = 0.7,
        topP: Double = 1.0,
        maxTokens: Int? = nil,
        contextWindowSize: Int = 8192,
        selectedSystemPromptId: UUID? = nil,
        workspacePromptIds: [UUID] = [],
        selectedPersonalityId: UUID? = nil,
        enableReasoning: Bool = true,
        enableTools: Bool = true,
        autoApprove: Bool = false,
        enableTerminalAccess: Bool = false,
        enableWorkflowMode: Bool = false,
        enableDynamicIterations: Bool = false,
        scrollLockEnabled: Bool = true,
        draftMessage: String = "",
        sdNegativePrompt: String = "",
        sdSteps: Int = 25,
        sdGuidanceScale: Float = 8.0,
        sdScheduler: String = "dpm++",
        sdSeed: Int = -1,
        sdUseKarras: Bool = true,
        sdImageCount: Int = 1,
        sdImageWidth: Int = 512,
        sdImageHeight: Int = 512,
        sdEngine: String = "coreml",
        sdDevice: String = "auto",
        sdUpscaleModel: String = "none",
        sdStrength: Double = 0.75,
        sdInputImagePath: String? = nil,
        showingMemoryPanel: Bool = false,
        showingTerminalPanel: Bool = false,
        showingWorkingDirectoryPanel: Bool = false,
        showAdvancedParameters: Bool = false,
        showingPerformanceMetrics: Bool = false,
        telemetry: ConversationTelemetry = ConversationTelemetry()
    ) {
        self.selectedModel = selectedModel
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.contextWindowSize = contextWindowSize
        self.workspacePromptIds = workspacePromptIds
        
        /// Default to user's selected default personality if none specified
        /// This ensures new conversations inherit the personality preference
        if let providedPersonalityId = selectedPersonalityId {
            self.selectedPersonalityId = providedPersonalityId
        } else {
            // Get default personality from PersonalityManager
            // This is synchronous and safe as PersonalityManager is @MainActor
            if let defaultId = UUID(uuidString: UserDefaults.standard.string(forKey: "defaultPersonalityId") ?? "") {
                self.selectedPersonalityId = defaultId
            } else {
                // Fallback to Assistant (first default personality)
                self.selectedPersonalityId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")
            }
        }
        
        self.enableReasoning = enableReasoning
        self.enableTools = enableTools
        self.autoApprove = autoApprove
        self.enableTerminalAccess = enableTerminalAccess
        self.enableWorkflowMode = enableWorkflowMode
        self.enableDynamicIterations = enableDynamicIterations
        self.scrollLockEnabled = scrollLockEnabled
        self.useSharedData = false
        self.sharedTopicId = nil
        self.sharedTopicName = nil
        self.draftMessage = draftMessage
        self.sdNegativePrompt = sdNegativePrompt
        self.sdSteps = sdSteps
        self.sdGuidanceScale = sdGuidanceScale
        self.sdScheduler = sdScheduler
        self.sdSeed = sdSeed
        self.sdUseKarras = sdUseKarras
        self.sdImageCount = sdImageCount
        self.sdImageWidth = sdImageWidth
        self.sdImageHeight = sdImageHeight
        self.sdEngine = sdEngine
        self.sdDevice = sdDevice
        self.sdUpscaleModel = sdUpscaleModel
        self.sdStrength = sdStrength
        self.sdInputImagePath = sdInputImagePath
        self.showingMemoryPanel = showingMemoryPanel
        self.showingTerminalPanel = showingTerminalPanel
        self.showingWorkingDirectoryPanel = showingWorkingDirectoryPanel
        self.showAdvancedParameters = showAdvancedParameters
        self.showingPerformanceMetrics = showingPerformanceMetrics
        self.telemetry = telemetry

        /// Default to SAM Default system prompt if none specified This ensures guard rails are always active in API calls and UI.
        if let providedPromptId = selectedSystemPromptId {
            self.selectedSystemPromptId = providedPromptId
        } else {
            /// Import SystemPromptManager to get SAM Default ID We'll set this to SystemPromptManager.shared.selectedConfigurationId after initialization For now, keep it nil and rely on SystemPromptManager to provide the default.
            self.selectedSystemPromptId = nil
        }
    }

    // MARK: - Custom Decoding for Backward Compatibility

    enum CodingKeys: String, CodingKey {
        case selectedModel, temperature, topP, maxTokens, contextWindowSize
        case selectedSystemPromptId, workspacePromptIds, selectedPersonalityId
        case enableReasoning, enableTools, autoApprove, enableTerminalAccess, enableWorkflowMode, enableDynamicIterations
        case scrollLockEnabled
        case useSharedData, sharedTopicId, sharedTopicName
        case draftMessage
        case sdNegativePrompt, sdSteps, sdGuidanceScale, sdScheduler, sdSeed, sdUseKarras, sdImageCount, sdImageWidth, sdImageHeight
        case sdEngine, sdDevice, sdUpscaleModel
        case sdStrength, sdInputImagePath
        case showingMemoryPanel, showingTerminalPanel, showingWorkingDirectoryPanel, showAdvancedParameters, showingPerformanceMetrics
        case telemetry
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        selectedModel = try container.decode(String.self, forKey: .selectedModel)
        temperature = try container.decode(Double.self, forKey: .temperature)
        topP = try container.decode(Double.self, forKey: .topP)
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
        contextWindowSize = try container.decode(Int.self, forKey: .contextWindowSize)
        selectedSystemPromptId = try container.decodeIfPresent(UUID.self, forKey: .selectedSystemPromptId)

        /// NEW FIELD: Default to empty array if not present (for old conversations).
        workspacePromptIds = try container.decodeIfPresent([UUID].self, forKey: .workspacePromptIds) ?? []

        /// NEW FIELD: Default to nil if not present (for old conversations).
        selectedPersonalityId = try container.decodeIfPresent(UUID.self, forKey: .selectedPersonalityId)

        enableReasoning = try container.decode(Bool.self, forKey: .enableReasoning)
        enableTools = try container.decode(Bool.self, forKey: .enableTools)
        autoApprove = try container.decode(Bool.self, forKey: .autoApprove)
        enableTerminalAccess = try container.decode(Bool.self, forKey: .enableTerminalAccess)

        /// NEW FIELD: Default to false if not present (for old conversations).
        enableWorkflowMode = try container.decodeIfPresent(Bool.self, forKey: .enableWorkflowMode) ?? false

        /// NEW FIELD: Default to false if not present (for old conversations).
        enableDynamicIterations = try container.decodeIfPresent(Bool.self, forKey: .enableDynamicIterations) ?? false

        /// NEW FIELD: Default to true if not present (for old conversations).
        scrollLockEnabled = try container.decodeIfPresent(Bool.self, forKey: .scrollLockEnabled) ?? true
        useSharedData = try container.decodeIfPresent(Bool.self, forKey: .useSharedData) ?? false
        sharedTopicId = try container.decodeIfPresent(UUID.self, forKey: .sharedTopicId)
        sharedTopicName = try container.decodeIfPresent(String.self, forKey: .sharedTopicName)

        /// NEW FIELD: Default to empty string if not present (for old conversations).
        draftMessage = try container.decodeIfPresent(String.self, forKey: .draftMessage) ?? ""

        /// Stable Diffusion parameters with defaults for backward compatibility.
        sdNegativePrompt = try container.decodeIfPresent(String.self, forKey: .sdNegativePrompt) ?? ""
        sdSteps = try container.decodeIfPresent(Int.self, forKey: .sdSteps) ?? 25
        sdGuidanceScale = try container.decodeIfPresent(Float.self, forKey: .sdGuidanceScale) ?? 8.0
        sdScheduler = try container.decodeIfPresent(String.self, forKey: .sdScheduler) ?? "dpm++"
        sdSeed = try container.decodeIfPresent(Int.self, forKey: .sdSeed) ?? -1
        sdUseKarras = try container.decodeIfPresent(Bool.self, forKey: .sdUseKarras) ?? true
        sdImageCount = try container.decodeIfPresent(Int.self, forKey: .sdImageCount) ?? 1
        sdImageWidth = try container.decodeIfPresent(Int.self, forKey: .sdImageWidth) ?? 512
        sdImageHeight = try container.decodeIfPresent(Int.self, forKey: .sdImageHeight) ?? 512
        sdEngine = try container.decodeIfPresent(String.self, forKey: .sdEngine) ?? "coreml"
        sdDevice = try container.decodeIfPresent(String.self, forKey: .sdDevice) ?? "auto"
        sdUpscaleModel = try container.decodeIfPresent(String.self, forKey: .sdUpscaleModel) ?? "none"
        sdStrength = try container.decodeIfPresent(Double.self, forKey: .sdStrength) ?? 0.75
        sdInputImagePath = try container.decodeIfPresent(String.self, forKey: .sdInputImagePath)

        /// UI panel visibility states with defaults for backward compatibility
        showingMemoryPanel = try container.decodeIfPresent(Bool.self, forKey: .showingMemoryPanel) ?? false
        showingTerminalPanel = try container.decodeIfPresent(Bool.self, forKey: .showingTerminalPanel) ?? false
        showingWorkingDirectoryPanel = try container.decodeIfPresent(Bool.self, forKey: .showingWorkingDirectoryPanel) ?? false
        showAdvancedParameters = try container.decodeIfPresent(Bool.self, forKey: .showAdvancedParameters) ?? false
        showingPerformanceMetrics = try container.decodeIfPresent(Bool.self, forKey: .showingPerformanceMetrics) ?? false
        
        /// Telemetry - default to empty if not present (for old conversations)
        telemetry = try container.decodeIfPresent(ConversationTelemetry.self, forKey: .telemetry) ?? ConversationTelemetry()
    }
}

// MARK: - Persistence Data Structure

public struct ConversationData: Codable, Sendable {
    public let id: UUID
    public let title: String
    public let created: Date
    public let updated: Date
    public let messages: [ConfigurationSystem.EnhancedMessage]
    public let settings: ConversationSettings?
    public let sessionId: String?
    public let lastGitHubCopilotResponseId: String?
    public let contextMessages: [ConfigurationSystem.EnhancedMessage]?
    public let isPinned: Bool?
    public let workingDirectory: String?
    public let workingDirectoryBookmark: Data?
    public let enabledMiniPromptIds: [UUID]?

    /// Subagent metadata for workflow delegation.
    public let isSubagent: Bool?
    public let parentConversationId: UUID?
    public let isWorking: Bool?
    public let subagentIds: [UUID]?

    /// Folder organization - conversations can be grouped into folders
    public let folderId: String?

    /// Track if conversation was created via API (for UI filtering)
    public let isFromAPI: Bool?

    public init(id: UUID, title: String, created: Date, updated: Date, messages: [ConfigurationSystem.EnhancedMessage], settings: ConversationSettings, sessionId: String? = nil, lastGitHubCopilotResponseId: String? = nil, contextMessages: [ConfigurationSystem.EnhancedMessage]? = nil, isPinned: Bool = false, workingDirectory: String? = nil, workingDirectoryBookmark: Data? = nil, enabledMiniPromptIds: [UUID]? = nil, isSubagent: Bool? = nil, parentConversationId: UUID? = nil, isWorking: Bool? = nil, subagentIds: [UUID]? = nil, folderId: String? = nil, isFromAPI: Bool = false) {
        self.id = id
        self.title = title
        self.created = created
        self.updated = updated
        self.messages = messages
        self.settings = settings
        self.sessionId = sessionId
        self.lastGitHubCopilotResponseId = lastGitHubCopilotResponseId
        self.contextMessages = contextMessages
        self.isPinned = isPinned
        self.workingDirectory = workingDirectory
        self.workingDirectoryBookmark = workingDirectoryBookmark
        self.enabledMiniPromptIds = enabledMiniPromptIds
        self.isSubagent = isSubagent
        self.parentConversationId = parentConversationId
        self.isWorking = isWorking
        self.subagentIds = subagentIds
        self.folderId = folderId
        self.isFromAPI = isFromAPI
    }
}

// MARK: - Runtime Conversation Model

@MainActor
public class ConversationModel: ObservableObject, Identifiable {
    /// Message bus - single source of truth for messages
    public var messageBus: ConversationMessageBus?

    /// Weak reference to parent ConversationManager for change propagation
    /// When messages update, we notify the manager to trigger SwiftUI re-renders
    public weak var manager: ConversationManager?

    /// Subscription to MessageBus changes (relays updates to ChatWidget)
    private var messageBusSubscription: AnyCancellable?

    /// Messages synced from MessageBus (single source of truth)
    /// This property is automatically kept in sync with MessageBus
    @Published public var messages: [ConfigurationSystem.EnhancedMessage] = []

    @Published public var title: String = "New Conversation"
    @Published public var isProcessing = false
    @Published public var settings = ConversationSettings()
    @Published public var sessionId: String?

    /// Last GitHub Copilot response ID for billing continuity Stored separately from messages to survive context pruning/summarization Used for checkpoint slicing to prevent multiple premium charges.
    @Published public var lastGitHubCopilotResponseId: String?

    /// Context messages for LLM (may be pruned/summarized) This is separate from 'messages' to allow context pruning without affecting UI display When nil, use 'messages' for LLM context (no pruning has occurred).
    @Published public var contextMessages: [ConfigurationSystem.EnhancedMessage]?

    /// Pinned conversations stay at top of list and are never auto-pruned.
    @Published public var isPinned: Bool = false

    /// Enabled mini-prompt IDs for this conversation Allows per-conversation context injection (e.g., location context only when relevant).
    @Published public var enabledMiniPromptIds: Set<UUID> = []

    /// Subagent metadata for workflow delegation.
    @Published public var isSubagent: Bool = false
    @Published public var parentConversationId: UUID?
    @Published public var isWorking: Bool = false
    @Published public var subagentIds: [UUID] = []

    /// Folder organization - conversations can be grouped into folders
    @Published public var folderId: String?

    /// Track if conversation was created via API (for UI filtering)
    @Published public var isFromAPI: Bool = false

    /// Working directory for terminal operations and file access Default: {basePath}/<conversation-id>/ (per-conversation isolation, App Store compliant, user can select different folder via picker).
    public var workingDirectory: String

    /// Security-scoped bookmark data for working directory (when user selects custom folder).
    public var workingDirectoryBookmark: Data?

    public let id: UUID
    public let created: Date
    @Published public var updated = Date()

    public init() {
        let defaultTitle = "New Conversation"
        self.id = UUID()
        self.created = Date()
        self.title = defaultTitle

        /// Use conversation title for directory name (sanitized)
        let safeName = defaultTitle.replacingOccurrences(of: "/", with: "-")
        let conversationDirectory = NSString(string: "~/SAM/\(safeName)/").expandingTildeInPath
        self.workingDirectory = conversationDirectory
        self.workingDirectoryBookmark = nil

        /// Create ~/SAM/<title>/ directory if it doesn't exist
        try? FileManager.default.createDirectory(
            atPath: conversationDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    /// Initialize with specific title (uses title for directory name)
    public init(title: String) {
        self.id = UUID()
        self.created = Date()
        self.title = title

        /// Initialize sessionId for GitHub Copilot billing continuity.
        /// Per VS Code Copilot protocol: sessionId should be set at conversation creation.
        /// This enables proper copilot_thread_id propagation and prevents duplicate billing.
        self.sessionId = self.id.uuidString

        /// Use conversation title for directory name (sanitized)
        let safeName = title.replacingOccurrences(of: "/", with: "-")
        let conversationDirectory = NSString(string: "~/SAM/\(safeName)/").expandingTildeInPath
        self.workingDirectory = conversationDirectory
        self.workingDirectoryBookmark = nil

        /// Create ~/SAM/<title>/ directory if it doesn't exist
        try? FileManager.default.createDirectory(
            atPath: conversationDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    /// Initialize with specific UUID (for API conversation persistence).
    public convenience init(id: UUID) {
        self.init()
        /// Replace default UUID with specified one This is a workaround since we can't reassign the let property after init We use the from(data:) factory instead.
    }

    /// Initialize conversation with specific UUID and settings (for API requests).
    public static func withId(_ id: UUID, title: String = "API Chat", settings: ConversationSettings = ConversationSettings(), folderId: String? = nil) -> ConversationModel {
        /// Default working directory: ~/SAM/<title>/ or ~/SAM/<folderId>/ (NOT UUID)
        let directoryName: String
        if let folderId = folderId {
            directoryName = folderId
        } else {
            /// Use conversation title for directory name (sanitized)
            directoryName = title.replacingOccurrences(of: "/", with: "-")
        }
        let conversationDirectory = NSString(string: "~/SAM/\(directoryName)/").expandingTildeInPath

        let data = ConversationData(
            id: id,
            title: title,
            created: Date(),
            updated: Date(),
            messages: [],
            settings: settings,
            sessionId: id.uuidString,
            workingDirectory: conversationDirectory,
            folderId: folderId,
            isFromAPI: true  // Mark API-created conversations
        )
        return ConversationModel.from(data: data)
    }

    private init(id: UUID, created: Date, title: String, updated: Date, messages: [ConfigurationSystem.EnhancedMessage], settings: ConversationSettings, sessionId: String? = nil, lastGitHubCopilotResponseId: String? = nil, contextMessages: [ConfigurationSystem.EnhancedMessage]? = nil, isPinned: Bool = false, workingDirectory: String? = nil, workingDirectoryBookmark: Data? = nil, enabledMiniPromptIds: Set<UUID> = [], isSubagent: Bool = false, parentConversationId: UUID? = nil, isWorking: Bool = false, subagentIds: [UUID] = [], folderId: String? = nil, isFromAPI: Bool = false) {
        self.id = id
        self.created = created
        self.title = title
        self.updated = updated
        self.messages = messages
        self.settings = settings
        self.sessionId = sessionId
        self.lastGitHubCopilotResponseId = lastGitHubCopilotResponseId
        self.contextMessages = contextMessages
        self.isPinned = isPinned
        self.workingDirectoryBookmark = workingDirectoryBookmark
        self.enabledMiniPromptIds = enabledMiniPromptIds
        self.isSubagent = isSubagent
        self.parentConversationId = parentConversationId
        self.isWorking = isWorking
        self.subagentIds = subagentIds
        self.folderId = folderId
        self.isFromAPI = isFromAPI

        /// Set working directory (use provided or default to ~/SAM/).
        if let providedWorkingDir = workingDirectory {
            self.workingDirectory = providedWorkingDir
        } else {
            /// Default to ~/SAM/ (App Store compliant).
            let samDirectory = NSString(string: "~/SAM/").expandingTildeInPath
            self.workingDirectory = samDirectory
        }

        /// Create working directory if it doesn't exist.
        try? FileManager.default.createDirectory(atPath: self.workingDirectory, withIntermediateDirectories: true, attributes: nil)
    }

    // MARK: - Persistence Conversion

    /// Convert to persistent data structure.
    public func toConversationData() -> ConversationData {
        return ConversationData(
            id: id,
            title: title,
            created: created,
            updated: updated,
            messages: messages,
            settings: settings,
            sessionId: sessionId,
            lastGitHubCopilotResponseId: lastGitHubCopilotResponseId,
            contextMessages: contextMessages,
            isPinned: isPinned,
            workingDirectory: workingDirectory,
            workingDirectoryBookmark: workingDirectoryBookmark,
            enabledMiniPromptIds: Array(enabledMiniPromptIds),
            isSubagent: isSubagent,
            parentConversationId: parentConversationId,
            isWorking: isWorking,
            subagentIds: subagentIds,
            folderId: folderId,
            isFromAPI: isFromAPI
        )
    }

    /// Initialize from persistent data structure.
    public static func from(data: ConversationData) -> ConversationModel {
        return ConversationModel(
            id: data.id,
            created: data.created,
            title: data.title,
            updated: data.updated,
            messages: data.messages,
            settings: data.settings ?? ConversationSettings(),
            sessionId: data.sessionId,
            lastGitHubCopilotResponseId: data.lastGitHubCopilotResponseId,
            contextMessages: data.contextMessages,
            isPinned: data.isPinned ?? false,
            workingDirectory: data.workingDirectory,
            workingDirectoryBookmark: data.workingDirectoryBookmark,
            enabledMiniPromptIds: Set(data.enabledMiniPromptIds ?? []),
            isSubagent: data.isSubagent ?? false,
            parentConversationId: data.parentConversationId,
            isWorking: data.isWorking ?? false,
            subagentIds: data.subagentIds ?? [],
            folderId: data.folderId,
            isFromAPI: data.isFromAPI ?? false
        )
    }

    /// LEGACY: Deprecated in favor of MessageBus.addUserMessage() or MessageBus.addAssistantMessage()
    /// This method is maintained for backward compatibility but will be removed in future versions.
    /// New code should use: conversation.messageBus?.addUserMessage() or conversation.messageBus?.addAssistantMessage()
    @available(*, deprecated, message: "Use conversation.messageBus?.addUserMessage() or addAssistantMessage() instead")
    public func addMessage(text: String, isUser: Bool, performanceMetrics: ConfigurationSystem.MessagePerformanceMetrics? = nil, githubCopilotResponseId: String? = nil, isPinned: Bool? = nil, importance: Double? = nil) {

        /// Extract reasoning content if present in the text.
        let (reasoning, messageType) = extractReasoningContent(from: text, isUser: isUser)

        /// AUTO-PIN LOGIC: Pin first 3 user messages for guaranteed context retrieval
        /// This ensures agents always have access to the initial request and constraints
        /// OVERRIDE: Allow explicit isPinned parameter to override auto-pin logic (for user_collaboration)
        let currentUserMessageCount = messages.filter { $0.isFromUser }.count
        let shouldPinMessage = isPinned ?? (isUser && currentUserMessageCount < 3)

        /// Calculate importance score (or use provided value)
        let finalImportance = importance ?? calculateMessageImportance(text: text, isUser: isUser)

        let message = ConfigurationSystem.EnhancedMessage(
            id: UUID(),
            type: messageType,
            content: text,
            isFromUser: isUser,
            timestamp: Date(),
            reasoningContent: reasoning,
            showReasoning: reasoning != nil,
            performanceMetrics: performanceMetrics,
            isStreaming: false,
            githubCopilotResponseId: githubCopilotResponseId,
            isPinned: shouldPinMessage,
            importance: finalImportance
        )
        messages.append(message)
        updated = Date()
    }

    /// LEGACY: Deprecated in favor of MessageBus.addToolMessage()
    /// This method is maintained for backward compatibility but will be removed in future versions.
    /// New code should use: conversation.messageBus?.addToolMessage(...)
    @available(*, deprecated, message: "Use conversation.messageBus?.addToolMessage() instead")
    public func addToolMessage(toolName: String, content: String, status: ConfigurationSystem.ToolStatus, duration: TimeInterval? = nil, icon: String? = nil, details: [String]? = nil, toolCallId: String? = nil) {
        let message = ConfigurationSystem.EnhancedMessage(
            id: UUID(),
            type: .toolExecution,
            content: content,
            isFromUser: false,
            timestamp: Date(),
            toolName: toolName,
            toolStatus: status,
            toolDetails: details,
            toolDuration: duration,
            toolIcon: icon,
            toolCategory: nil,
            parentToolName: nil,
            toolMetadata: nil,
            toolCalls: nil,
            toolCallId: toolCallId,
            processingTime: duration,
            reasoningContent: nil,
            showReasoning: false,
            performanceMetrics: nil,
            isStreaming: false,
            isToolMessage: true
        )
        messages.append(message)
        updated = Date()
    }

    /// Extract reasoning content from message text Returns: (reasoningContent, messageType).
    private func extractReasoningContent(from text: String, isUser: Bool) -> (String?, ConfigurationSystem.MessageType) {
        /// User messages don't have reasoning.
        guard !isUser else {
            return (nil, .user)
        }

        /// Format 1: ThinkTagFormatter output with separator "Thinking: [reasoning]\n\n---\n\n[response]".
        if text.hasPrefix("Thinking:") {
            if let separatorRange = text.range(of: "\n\n---\n\n") {
                /// Extract reasoning between "Thinking:" and separator.
                let reasoningStart = text.index(text.startIndex, offsetBy: "Thinking:".count)
                let reasoning = String(text[reasoningStart..<separatorRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !reasoning.isEmpty {
                    return (reasoning, .thinking)
                }
            } else {
                /// No separator found but has "Thinking:" prefix - might be incomplete.
                let reasoningStart = text.index(text.startIndex, offsetBy: "Thinking:".count)
                let reasoning = String(text[reasoningStart...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !reasoning.isEmpty {
                    return (reasoning, .thinking)
                }
            }
        }

        /// Format 2: Tool message format "SUCCESS: Thinking: [content]".
        if text.lowercased().hasPrefix("SUCCESS: thinking:") {
            let startIndex = text.index(text.startIndex, offsetBy: "SUCCESS: Thinking:".count)
            let reasoning = String(text[startIndex...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            /// Exclude placeholder messages like "SUCCESS: Thinking...".
            if !reasoning.isEmpty && reasoning != "..." {
                return (reasoning, .thinking)
            }
        }

        /// No reasoning found - regular assistant message.
        return (nil, .assistant)
    }

    // MARK: - Intelligent Importance Scoring

    /// Calculate importance score for message based on content and type Higher scores (closer to 1.0) = more important, more likely to be retrieved.
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

    /// LEGACY: Deprecated in favor of MessageBus.clearMessages()
    /// This method is maintained for backward compatibility but will be removed in future versions.
    /// New code should use: conversation.messageBus?.clearMessages()
    @available(*, deprecated, message: "Use conversation.messageBus?.clearMessages() instead")
    public func clearMessages() {
        messages.removeAll()
        updated = Date()
    }

    // MARK: - MessageBus Integration

    /// Initialize message bus (call after conversation creation)
    public func initializeMessageBus(conversationManager: ConversationManager) {
        self.messageBus = ConversationMessageBus(
            conversation: self,
            conversationManager: conversationManager
        )

        /// Load existing messages INTO MessageBus (for conversations loaded from disk)
        /// IMPORTANT: Do this BEFORE setting up subscription to avoid sync loops
        if !messages.isEmpty, let messageBus = self.messageBus {
            /// Directly load messages into MessageBus without triggering add methods
            /// This avoids circular subscription triggers during initialization
            messageBus.loadMessagesDirectly(messages)
        }

        /// Subscribe to MessageBus changes and sync messages array
        /// This ensures ConversationModel.messages stays in sync with MessageBus
        messageBusSubscription = messageBus?.objectWillChange
            .sink { [weak self] _ in
                guard let self = self, let messageBus = self.messageBus else { return }
                /// Sync messages from MessageBus to ConversationModel
                self.messages = messageBus.messages
                /// Relay change to ConversationModel's observers (ChatWidget)
                self.objectWillChange.send()
            }

        /// Final sync to ensure messages array reflects MessageBus
        if let messageBus = self.messageBus {
            self.messages = messageBus.messages
        }
    }

    /// Sync messages from MessageBus (called by MessageBus when messages change)
    public func syncMessagesFromMessageBus() {
        let perfStart = CFAbsoluteTimeGetCurrent()
        defer {
            InternalOperationMonitor.shared.record("ConversationModel.syncMessagesFromMessageBus",
                                            duration: CFAbsoluteTimeGetCurrent() - perfStart)
        }

        guard let messageBus = self.messageBus else { return }
        messages = messageBus.messages

        /// PERFORMANCE: Explicitly send objectWillChange for immediate UI update
        /// MessageBus @Published changes are observed directly by ChatWidget via @ObservedObject
        /// No need for manager.objectWillChange.send() - ChatWidget observes MessageBus directly
        objectWillChange.send()
    }

    /// DELTA SYNC: Update single message without copying entire array
    /// Used during streaming to avoid performance bottleneck
    public func updateMessage(at index: Int, with message: EnhancedMessage) {
        let perfStart = CFAbsoluteTimeGetCurrent()
        defer {
            InternalOperationMonitor.shared.record("ConversationModel.updateMessage",
                                            duration: CFAbsoluteTimeGetCurrent() - perfStart)
        }

        guard index >= 0 && index < messages.count else { return }
        messages[index] = message

        /// PERFORMANCE: Explicitly send objectWillChange for immediate UI update
        /// MessageBus @Published changes are observed directly by ChatWidget via @ObservedObject
        /// No need for manager.objectWillChange.send() - ChatWidget observes MessageBus directly
        objectWillChange.send()
    }
}
