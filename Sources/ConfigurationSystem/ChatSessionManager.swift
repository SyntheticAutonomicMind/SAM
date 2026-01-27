// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

// MARK: - Logging

/// Local logger for ChatSessionManager to avoid circular dependencies.
private let sessionLogger = Logger(label: "com.sam.config.ChatSessionManager")

// MARK: - Performance Metrics (Local copy to avoid circular dependency)

/// Performance metrics for a message response (local copy to avoid circular dependency with ConversationEngine).
public struct MessagePerformanceMetrics: Codable, Hashable, Sendable {
    public let tokenCount: Int
    public let timeToFirstToken: TimeInterval
    public let tokensPerSecond: Double
    public let processingTime: TimeInterval

    public init(tokenCount: Int, timeToFirstToken: TimeInterval, tokensPerSecond: Double, processingTime: TimeInterval) {
        self.tokenCount = tokenCount
        self.timeToFirstToken = timeToFirstToken
        self.tokensPerSecond = tokensPerSecond
        self.processingTime = processingTime
    }
}

// MARK: - Message Type Classification

/// Classification of message types for specialized rendering.
public enum MessageType: String, Codable, Sendable {
    case user
    case assistant
    case toolExecution
    case subagentExecution
    case systemStatus
    case thinking
}

/// Status of tool execution for visual indicators.
public enum ToolStatus: String, Codable, Sendable {
    case queued
    case running
    case success
    case error
    case userInputRequired
}

/// Structured display data for tool execution UI
public struct ToolDisplayData: Codable, Sendable, Hashable {
    /// Machine-readable action identifier (e.g. "researching", "creating")
    public let action: String

    /// Human-friendly action name for UI display (e.g. "Web Search", "Create File")
    public let actionDisplayName: String

    /// One-line summary for collapsed card state
    public let summary: String?

    /// Detailed information lines for expanded card state
    public let details: [String]?

    /// Current execution status
    public let status: ToolStatus

    /// SF Symbol icon name (e.g. "magnifyingglass", "brain.head.profile")
    public let icon: String?

    /// Tool-specific metadata for advanced features
    public let metadata: [String: String]?

    public init(
        action: String,
        actionDisplayName: String,
        summary: String? = nil,
        details: [String]? = nil,
        status: ToolStatus = .running,
        icon: String? = nil,
        metadata: [String: String]? = nil
    ) {
        self.action = action
        self.actionDisplayName = actionDisplayName
        self.summary = summary
        self.details = details
        self.status = status
        self.icon = icon
        self.metadata = metadata
    }
}

// MARK: - Tool Call Structures (OpenAI Compatible)

/// Simplified function call structure for tool calling (OpenAI compatible).
public struct SimpleFunctionCall: Codable, Hashable, Sendable {
    public let name: String
    public let arguments: String

    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}

/// Simplified tool call structure for preserving OpenAI tool calling format.
public struct SimpleToolCall: Codable, Hashable, Sendable {
    public let id: String
    public let type: String
    public let function: SimpleFunctionCall

    public init(id: String, type: String = "function", function: SimpleFunctionCall) {
        self.id = id
        self.type = type
        self.function = function
    }
}

// MARK: - Multi-Part Content Support (OpenAI Compatible)

/// Media content type for multi-modal messages.
public enum MediaContentType: String, Codable, Hashable {
    case image = "image_url"
    case video = "video_url"
    case audio = "audio_url"
}

/// Image detail level (for vision models).
public enum ImageDetail: String, Codable, Hashable, Sendable {
    case auto
    case low
    case high
}

/// Image URL structure for OpenAI vision API.
public struct ImageURL: Codable, Hashable, Sendable {
    public let url: String
    public let detail: ImageDetail?

    public init(url: String, detail: ImageDetail? = nil) {
        self.url = url
        self.detail = detail
    }
}

/// Content part for multi-modal messages (OpenAI format).
public enum MessageContentPart: Codable, Hashable, Sendable {
    case text(String)
    case imageUrl(ImageURL)
    case videoUrl(String)
    case audioUrl(String)

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageUrl = "image_url"
        case videoUrl = "video_url"
        case audioUrl = "audio_url"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "image_url":
            let imageUrl = try container.decode(ImageURL.self, forKey: .imageUrl)
            self = .imageUrl(imageUrl)
        case "video_url":
            let videoUrl = try container.decode(String.self, forKey: .videoUrl)
            self = .videoUrl(videoUrl)
        case "audio_url":
            let audioUrl = try container.decode(String.self, forKey: .audioUrl)
            self = .audioUrl(audioUrl)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown content part type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageUrl(let imageUrl):
            try container.encode("image_url", forKey: .type)
            try container.encode(imageUrl, forKey: .imageUrl)
        case .videoUrl(let url):
            try container.encode("video_url", forKey: .type)
            try container.encode(url, forKey: .videoUrl)
        case .audioUrl(let url):
            try container.encode("audio_url", forKey: .type)
            try container.encode(url, forKey: .audioUrl)
        }
    }
}

// MARK: - Enhanced Message Model

/// Represents a message in the chat with metadata and export capabilities.
public struct EnhancedMessage: Identifiable, Codable, Hashable, Sendable {
    // MARK: - Core Fields
    public let id: UUID
    public let type: MessageType
    public let content: String
    public let contentParts: [MessageContentPart]?
    public let timestamp: Date

    // MARK: - User/Assistant Fields (Legacy compatibility)
    public let isFromUser: Bool

    // MARK: - Tool/Subagent Fields
    public let toolName: String?
    public let toolStatus: ToolStatus?

    /// Structured tool display data (preferred for UI rendering)
    public let toolDisplayData: ToolDisplayData?

    public let toolDetails: [String]?
    public let toolDuration: TimeInterval?
    public let toolIcon: String?
    public let toolCategory: String?
    public let parentToolName: String?
    public let toolMetadata: [String: String]?

    // MARK: - OpenAI Tool Calling Fields (for preserving tool call structure)
    public let toolCalls: [SimpleToolCall]?
    public let toolCallId: String?

    // MARK: - Performance Metrics
    public let performanceMetrics: MessagePerformanceMetrics?
    public let processingTime: TimeInterval?

    // MARK: - Reasoning Fields
    public let reasoningContent: String?
    public let showReasoning: Bool

    // MARK: - Streaming State
    public var isStreaming: Bool = false

    // MARK: - UI Setup
    public let githubCopilotResponseId: String?

    // MARK: - Context Management Fields (for intelligent pruning)
    public let isPinned: Bool
    public let importance: Double
    public let lastModified: Date?

    // MARK: - System Messages
    /// True if this message was generated by the system (e.g., auto-continue prompts)
    /// System-generated messages should be hidden from UI but kept in conversation history
    public let isSystemGenerated: Bool

    // MARK: - Legacy Fields
    public let isToolMessage: Bool

    public init(
        id: UUID = UUID(),
        type: MessageType = .assistant,
        content: String,
        contentParts: [MessageContentPart]? = nil,
        isFromUser: Bool,
        timestamp: Date = Date(),
        toolName: String? = nil,
        toolStatus: ToolStatus? = nil,
        toolDisplayData: ToolDisplayData? = nil,
        toolDetails: [String]? = nil,
        toolDuration: TimeInterval? = nil,
        toolIcon: String? = nil,
        toolCategory: String? = nil,
        parentToolName: String? = nil,
        toolMetadata: [String: String]? = nil,
        toolCalls: [SimpleToolCall]? = nil,
        toolCallId: String? = nil,
        processingTime: TimeInterval? = nil,
        reasoningContent: String? = nil,
        showReasoning: Bool = false,
        performanceMetrics: MessagePerformanceMetrics? = nil,
        isStreaming: Bool = false,
        isToolMessage: Bool = false,
        githubCopilotResponseId: String? = nil,
        isPinned: Bool = false,
        importance: Double = 0.5,
        lastModified: Date? = nil,
        isSystemGenerated: Bool = false
    ) {
        self.id = id
        self.content = content
        self.contentParts = contentParts
        self.isFromUser = isFromUser
        self.timestamp = timestamp
        self.processingTime = processingTime
        self.reasoningContent = reasoningContent
        self.showReasoning = showReasoning
        self.performanceMetrics = performanceMetrics
        self.isStreaming = isStreaming

        /// Tool metadata.
        self.toolName = toolName
        self.toolStatus = toolStatus
        self.toolDisplayData = toolDisplayData
        self.toolDetails = toolDetails
        self.toolDuration = toolDuration
        self.toolIcon = toolIcon
        self.toolCategory = toolCategory
        self.parentToolName = parentToolName
        self.toolMetadata = toolMetadata

        /// OpenAI tool calling fields.
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId

        /// GitHub Copilot and context management.
        self.githubCopilotResponseId = githubCopilotResponseId
        self.isPinned = isPinned
        self.importance = importance
        self.lastModified = lastModified ?? timestamp
        self.isSystemGenerated = isSystemGenerated

        /// Message type determination (with backwards compatibility) Priority: explicit type > reasoning content > isToolMessage > isFromUser.
        if type == .thinking {
            /// Explicit thinking type (from agent or chat widget).
            self.type = .thinking
            self.isToolMessage = true
        } else if let content = reasoningContent, !content.isEmpty {
            /// Has reasoning content.
            self.type = .thinking
            self.isToolMessage = false
        } else if isToolMessage || type == .toolExecution {
            /// Regular tool execution.
            self.type = .toolExecution
            self.isToolMessage = true
        } else if isFromUser {
            /// User message.
            self.type = .user
            self.isToolMessage = false
        } else {
            /// Use provided type.
            self.type = type
            self.isToolMessage = isToolMessage
        }
    }

    /// Check if this message has reasoning content to display.
    public var hasReasoning: Bool {
        if let content = reasoningContent, !content.isEmpty {
            return true
        }
        return false
    }

    // MARK: - Properties
    private enum CodingKeys: String, CodingKey {
        case id, type, content, contentParts, timestamp, isFromUser
        case toolName, toolStatus, toolDisplayData, toolDetails, toolDuration, toolIcon, toolCategory, parentToolName, toolMetadata
        case toolCalls, toolCallId
        case performanceMetrics, processingTime
        case reasoningContent, showReasoning
        case isStreaming
        case githubCopilotResponseId
        case isPinned, importance, lastModified
        case isSystemGenerated
        case isToolMessage
    }

    // MARK: - Backward Compatibility Decoder
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(MessageType.self, forKey: .type)
        content = try container.decode(String.self, forKey: .content)

        /// NEW FIELD: Default to nil if not present (backward compatibility).
        contentParts = try container.decodeIfPresent([MessageContentPart].self, forKey: .contentParts)

        timestamp = try container.decode(Date.self, forKey: .timestamp)
        isFromUser = try container.decode(Bool.self, forKey: .isFromUser)

        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        toolStatus = try container.decodeIfPresent(ToolStatus.self, forKey: .toolStatus)
        toolDisplayData = try container.decodeIfPresent(ToolDisplayData.self, forKey: .toolDisplayData)
        toolDetails = try container.decodeIfPresent([String].self, forKey: .toolDetails)
        toolDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .toolDuration)
        toolIcon = try container.decodeIfPresent(String.self, forKey: .toolIcon)
        toolCategory = try container.decodeIfPresent(String.self, forKey: .toolCategory)
        parentToolName = try container.decodeIfPresent(String.self, forKey: .parentToolName)
        toolMetadata = try container.decodeIfPresent([String: String].self, forKey: .toolMetadata)

        toolCalls = try container.decodeIfPresent([SimpleToolCall].self, forKey: .toolCalls)
        toolCallId = try container.decodeIfPresent(String.self, forKey: .toolCallId)

        performanceMetrics = try container.decodeIfPresent(MessagePerformanceMetrics.self, forKey: .performanceMetrics)
        processingTime = try container.decodeIfPresent(TimeInterval.self, forKey: .processingTime)

        reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
        showReasoning = try container.decode(Bool.self, forKey: .showReasoning)

        isStreaming = try container.decode(Bool.self, forKey: .isStreaming)

        githubCopilotResponseId = try container.decodeIfPresent(String.self, forKey: .githubCopilotResponseId)

        /// Context management fields - with backward compatibility and migration logic
        /// Auto-pin first 3 user messages if isPinned field is missing (migration from old conversations)
        if let pinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) {
            isPinned = pinned
        } else {
            /// Missing isPinned field - apply migration logic
            /// This conversation was created before auto-pinning feature
            /// We'll need to check message position in the conversation to determine pinning
            /// For now, default to false - the conversation manager will handle migration
            isPinned = false
        }

        if let imp = try container.decodeIfPresent(Double.self, forKey: .importance) {
            importance = imp
        } else {
            /// Missing importance field - calculate based on message type
            /// User messages get 0.7, assistant messages get 0.5 as defaults
            importance = isFromUser ? 0.7 : 0.5
        }

        lastModified = try container.decodeIfPresent(Date.self, forKey: .lastModified)

        /// System-generated flag - default to false for backward compatibility
        isSystemGenerated = try container.decodeIfPresent(Bool.self, forKey: .isSystemGenerated) ?? false

        isToolMessage = try container.decode(Bool.self, forKey: .isToolMessage)
    }
}

// MARK: - Chat Session Models

/// Represents a complete chat session with all configuration and messages.
public struct ChatSession: Codable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var messages: [EnhancedMessage]
    public var configuration: ChatConfiguration
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String = "New Chat",
        messages: [EnhancedMessage] = [],
        configuration: ChatConfiguration = ChatConfiguration()
    ) {
        self.id = id
        self.name = name
        self.messages = messages
        self.configuration = configuration
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// Create a duplicate of this chat session.
    public func duplicate(withName newName: String? = nil) -> ChatSession {
        ChatSession(
            name: newName ?? "\(name) (Copy)",
            messages: messages,
            configuration: configuration
        )
    }

    /// Export chat session to JSON.
    public func exportToJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Import chat session from JSON.
    public static func importFromJSON(_ data: Data) throws -> ChatSession {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ChatSession.self, from: data)
    }
}

/// Configuration settings for a chat session.
public struct ChatConfiguration: Codable, Hashable {
    public var selectedModel: String
    public var selectedProvider: String
    public var systemPrompt: String?
    public var temperature: Double
    public var topP: Double
    public var maxTokens: Int?
    public var showPerformanceMetrics: Bool
    public var enableReasoning: Bool
    public var autoShowReasoning: Bool

    public init(
        selectedModel: String = "gpt-4",
        selectedProvider: String = "GitHub Copilot",
        systemPrompt: String? = nil,
        temperature: Double = 0.7,
        topP: Double = 1.0,
        maxTokens: Int? = nil,
        showPerformanceMetrics: Bool = false,
        enableReasoning: Bool = false,
        autoShowReasoning: Bool = false
    ) {
        self.selectedModel = selectedModel
        self.selectedProvider = selectedProvider
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.showPerformanceMetrics = showPerformanceMetrics
        self.enableReasoning = enableReasoning
        self.autoShowReasoning = autoShowReasoning
    }
}

// MARK: - Chat Manager

@MainActor
public class ChatManager: ObservableObject {
    @Published public var chatSessions: [ChatSession] = []
    @Published public var currentSessionId: UUID?

    private let userDefaults = UserDefaults.standard
    private let chatSessionsKey = "SavedChatSessions"
    private let currentSessionKey = "CurrentChatSession"

    public init() {
        loadChatSessions()
    }

    public var currentSession: ChatSession? {
        get {
            guard let currentId = currentSessionId else { return nil }
            return chatSessions.first { $0.id == currentId }
        }
        set {
            if let newSession = newValue {
                updateSession(newSession)
                currentSessionId = newSession.id
            } else {
                currentSessionId = nil
            }
        }
    }

    // MARK: - Session Management

    public func createNewSession(name: String = "New Chat") -> ChatSession {
        let session = ChatSession(name: name)
        chatSessions.append(session)
        currentSessionId = session.id
        saveChatSessions()
        return session
    }

    public func duplicateSession(_ session: ChatSession, withName newName: String? = nil) -> ChatSession {
        let duplicatedSession = session.duplicate(withName: newName)
        chatSessions.append(duplicatedSession)
        saveChatSessions()
        return duplicatedSession
    }

    public func updateSession(_ session: ChatSession) {
        if let index = chatSessions.firstIndex(where: { $0.id == session.id }) {
            var updatedSession = session
            updatedSession.updatedAt = Date()
            chatSessions[index] = updatedSession
            saveChatSessions()
        }
    }

    public func deleteSession(_ session: ChatSession) {
        chatSessions.removeAll { $0.id == session.id }
        if currentSessionId == session.id {
            currentSessionId = chatSessions.first?.id
        }
        saveChatSessions()
    }

    public func renameSession(_ session: ChatSession, to newName: String) {
        if let index = chatSessions.firstIndex(where: { $0.id == session.id }) {
            var updatedSession = session
            updatedSession.name = newName
            updatedSession.updatedAt = Date()
            chatSessions[index] = updatedSession
            saveChatSessions()
        }
    }

    // MARK: - Import/Export

    public func exportSession(_ session: ChatSession) throws -> Data {
        return try session.exportToJSON()
    }

    public func exportAllSessions() throws -> Data {
        let exportData = [
            "version": "1.0",
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "sessions": chatSessions
        ] as [String: Any]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(AnyCodable(exportData))
    }

    public func importSession(from data: Data) throws -> ChatSession {
        let session = try ChatSession.importFromJSON(data)
        chatSessions.append(session)
        saveChatSessions()
        return session
    }

    // MARK: - Persistence

    private func loadChatSessions() {
        guard let data = userDefaults.data(forKey: chatSessionsKey) else { return }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            chatSessions = try decoder.decode([ChatSession].self, from: data)

            /// Load current session ID.
            if let currentIdString = userDefaults.string(forKey: currentSessionKey),
               let currentId = UUID(uuidString: currentIdString) {
                currentSessionId = currentId
            }
        } catch {
            sessionLogger.error("Failed to load chat sessions: \(error)")
            chatSessions = []
        }
    }

    private func saveChatSessions() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(chatSessions)
            userDefaults.set(data, forKey: chatSessionsKey)

            /// Save current session ID.
            if let currentId = currentSessionId {
                userDefaults.set(currentId.uuidString, forKey: currentSessionKey)
            }
        } catch {
            sessionLogger.error("Failed to save chat sessions: \(error)")
        }
    }
}

// MARK: - Helper Methods

private struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case let string as String:
            try container.encode(string)

        case let int as Int:
            try container.encode(int)

        case let double as Double:
            try container.encode(double)

        case let bool as Bool:
            try container.encode(bool)

        case let array as [Any]:
            try container.encode(array.map(AnyCodable.init))

        case let dict as [String: Any]:
            try container.encode(dict.mapValues(AnyCodable.init))

        case let codable as Codable:
            try (codable as Encodable).encode(to: encoder)

        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Invalid value"))
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid value"))
        }
    }
}
