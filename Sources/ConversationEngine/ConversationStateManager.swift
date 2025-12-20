// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Combine

/// Centralized runtime state management for conversations
/// Tracks ephemeral state that should NOT be persisted to disk (processing status, active tools, etc.)
/// State persists across conversation switches enabling proper UI display for background conversations
@MainActor
public class ConversationStateManager: ObservableObject {
    /// Published dictionary of all conversation states
    /// Key: Conversation UUID, Value: Runtime state
    @Published public private(set) var states: [UUID: ConversationRuntimeState] = [:]

    /// Active sessions per conversation
    /// Key: Conversation UUID, Value: Active session (if any)
    private var activeSessions: [UUID: ConversationSession] = [:]

    /// Lock for thread-safe session access
    private let sessionsLock = NSLock()

    /// Runtime state for a single conversation
    public struct ConversationRuntimeState: Equatable {
        public var status: RuntimeStatus
        public var activeTools: Set<String>
        public var modelLoaded: Bool
        public var terminalSessionId: String?
        public var activeSessionId: UUID?  // Track which session is active

        public init(
            status: RuntimeStatus = .idle,
            activeTools: Set<String> = [],
            modelLoaded: Bool = false,
            terminalSessionId: String? = nil,
            activeSessionId: UUID? = nil
        ) {
            self.status = status
            self.activeTools = activeTools
            self.modelLoaded = modelLoaded
            self.terminalSessionId = terminalSessionId
            self.activeSessionId = activeSessionId
        }
    }

    /// Runtime status for processing state
    public enum RuntimeStatus: Equatable {
        case idle
        case processing(toolName: String?)
        case streaming
        case error(String)
    }

    /// Update state for a conversation
    /// - Parameters:
    ///   - conversationId: UUID of conversation to update
    ///   - update: Closure that modifies the state
    public func updateState(conversationId: UUID, _ update: (inout ConversationRuntimeState) -> Void) {
        var state = states[conversationId] ?? ConversationRuntimeState()
        update(&state)
        states[conversationId] = state

        /// Force SwiftUI update for dictionary change
        objectWillChange.send()
    }

    /// Get current state for a conversation
    /// - Parameter conversationId: UUID of conversation
    /// - Returns: Current runtime state, or nil if not tracked
    public func getState(conversationId: UUID) -> ConversationRuntimeState? {
        return states[conversationId]
    }

    /// Clear state for a conversation (typically when deleted)
    /// - Parameter conversationId: UUID of conversation to clear
    public func clearState(conversationId: UUID) {
        states.removeValue(forKey: conversationId)

        /// Force SwiftUI update
        objectWillChange.send()

        // Also invalidate and remove any active session
        sessionsLock.lock()
        defer { sessionsLock.unlock() }

        if let session = activeSessions[conversationId] {
            session.invalidate()
            activeSessions.removeValue(forKey: conversationId)
        }
    }

    /// Get or create state for conversation (convenience method)
    /// - Parameter conversationId: UUID of conversation
    /// - Returns: Existing state or newly created idle state
    public func getOrCreateState(conversationId: UUID) -> ConversationRuntimeState {
        if let existing = states[conversationId] {
            return existing
        }
        let newState = ConversationRuntimeState()
        states[conversationId] = newState
        return newState
    }

    // MARK: - Session Management

    /// Register an active session for a conversation
    /// - Parameters:
    ///   - session: The conversation session
    ///   - conversationId: UUID of conversation
    public func registerSession(_ session: ConversationSession, for conversationId: UUID) {
        sessionsLock.lock()
        defer { sessionsLock.unlock() }

        activeSessions[conversationId] = session

        // Update state to track session
        updateState(conversationId: conversationId) { state in
            state.activeSessionId = conversationId
        }
    }

    /// Get active session for a conversation
    /// - Parameter conversationId: UUID of conversation
    /// - Returns: Active session if exists and valid
    public func getSession(for conversationId: UUID) -> ConversationSession? {
        sessionsLock.lock()
        defer { sessionsLock.unlock() }

        guard let session = activeSessions[conversationId] else {
            return nil
        }

        // Return nil if session is invalidated
        return session.canProceed ? session : nil
    }

    /// Invalidate session for a conversation
    /// - Parameter conversationId: UUID of conversation
    public func invalidateSession(for conversationId: UUID) {
        sessionsLock.lock()
        defer { sessionsLock.unlock() }

        if let session = activeSessions[conversationId] {
            session.invalidate()
            activeSessions.removeValue(forKey: conversationId)

            // Update state
            updateState(conversationId: conversationId) { state in
                state.activeSessionId = nil
            }
        }
    }
}
