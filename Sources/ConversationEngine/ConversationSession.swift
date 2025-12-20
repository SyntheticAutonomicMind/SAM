// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation

/// Errors related to conversation session management
public enum SessionError: Error, LocalizedError {
    case invalidated
    case conversationDeleted
    case conversationNotFound

    public var errorDescription: String? {
        switch self {
        case .invalidated:
            return "Session has been invalidated (conversation switched or deleted)"
        case .conversationDeleted:
            return "Conversation was deleted during operation"
        case .conversationNotFound:
            return "Conversation not found"
        }
    }
}

/// Snapshot of conversation context for safe async operations
/// Prevents data leakage when user switches conversations during agent work
/// Each async operation creates a session that captures conversation ID and context
/// Session validation ensures operations only affect the correct conversation
@MainActor
public class ConversationSession {
    /// Unique identifier for the conversation this session belongs to
    public let conversationId: UUID

    /// Working directory for this conversation (snapshot at session creation)
    public let workingDirectory: String

    /// Terminal manager instance for this conversation (if any)
    public let terminalManager: AnyObject?

    /// Timestamp when session was created
    public let createdAt: Date

    /// Whether this session is still valid
    /// Set to false when conversation is deleted or session explicitly invalidated
    private(set) var isValid: Bool = true

    /// Initialize a new conversation session
    /// - Parameters:
    ///   - conversationId: UUID of the conversation
    ///   - workingDirectory: Working directory path for file operations
    ///   - terminalManager: Terminal manager instance (optional)
    public init(
        conversationId: UUID,
        workingDirectory: String,
        terminalManager: AnyObject? = nil
    ) {
        self.conversationId = conversationId
        self.workingDirectory = workingDirectory
        self.terminalManager = terminalManager
        self.createdAt = Date()
    }

    /// Invalidate this session
    /// Called when conversation is deleted or switched
    public func invalidate() {
        isValid = false
    }

    /// Validate session is still valid
    /// - Throws: SessionError if session is invalidated
    public func validate() throws {
        guard isValid else {
            throw SessionError.invalidated
        }
    }

    /// Check if session can proceed without throwing
    /// Useful for graceful degradation in non-critical paths
    public var canProceed: Bool {
        return isValid
    }

    /// Get session age in seconds
    public var ageInSeconds: TimeInterval {
        return Date().timeIntervalSince(createdAt)
    }
}

/// Context information for conversation operations
/// Provides all necessary context for tools and async operations
public struct ConversationContext {
    public let conversationId: UUID
    public let workingDirectory: String
    public let terminalManager: AnyObject?

    public init(
        conversationId: UUID,
        workingDirectory: String,
        terminalManager: AnyObject? = nil
    ) {
        self.conversationId = conversationId
        self.workingDirectory = workingDirectory
        self.terminalManager = terminalManager
    }
}
