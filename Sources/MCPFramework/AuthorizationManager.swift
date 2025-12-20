// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Manages temporary authorizations granted via user_collaboration tool WORKFLOW: 1.
public class AuthorizationManager {
    public nonisolated(unsafe) static let shared = AuthorizationManager()

    private let logger = Logger(label: "com.sam.mcp.AuthorizationManager")
    private var authorizations: [AuthorizationGrant] = []
    private let lock = NSLock()

    /// Conversations with auto-approve enabled (bypasses all security).
    private var autoApproveConversations: Set<UUID> = []

    /// Default expiry time for authorizations (5 minutes).
    private let defaultExpirySeconds: TimeInterval = 300

    private init() {}

    /// Grant temporary authorization for a specific operation within a conversation - Parameters: - conversationId: The conversation where authorization was granted - operation: The operation to authorize (e.g., "terminal_operations.create_directory") - expirySeconds: How long the authorization is valid (default: 300 seconds) - oneTimeUse: If true, authorization is consumed after first use (default: true).
    public func grantAuthorization(
        conversationId: UUID,
        operation: String,
        expirySeconds: TimeInterval? = nil,
        oneTimeUse: Bool = true
    ) {
        lock.lock()
        defer { lock.unlock() }

        let expiry = Date().addingTimeInterval(expirySeconds ?? defaultExpirySeconds)
        let grant = AuthorizationGrant(
            id: UUID(),
            conversationId: conversationId,
            operation: operation,
            grantedAt: Date(),
            expiresAt: expiry,
            oneTimeUse: oneTimeUse,
            consumed: false
        )

        authorizations.append(grant)

        logger.debug("Authorization granted", metadata: [
            "conversationId": .string(conversationId.uuidString),
            "operation": .string(operation),
            "expiresIn": .stringConvertible(expirySeconds ?? defaultExpirySeconds),
            "oneTimeUse": .stringConvertible(oneTimeUse)
        ])
    }

    /// Check if an operation is authorized and consume the authorization if one-time use - Parameters: - conversationId: The conversation context - operation: The operation to check (e.g., "terminal_operations.create_directory") - Returns: True if authorized and not expired, false otherwise.
    public func isAuthorized(conversationId: UUID, operation: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        /// Check auto-approve first (bypasses all security).
        if autoApproveConversations.contains(conversationId) {
            logger.debug("Auto-approve enabled - bypassing authorization check", metadata: [
                "conversationId": .string(conversationId.uuidString),
                "operation": .string(operation)
            ])
            return true
        }

        /// Clean up expired authorizations.
        cleanupExpired()

        /// Find matching authorization.
        guard let index = authorizations.firstIndex(where: {
            $0.conversationId == conversationId &&
            $0.operation == operation &&
            !$0.consumed &&
            $0.expiresAt > Date()
        }) else {
            return false
        }

        /// Consume if one-time use.
        if authorizations[index].oneTimeUse {
            authorizations[index].consumed = true
            logger.debug("Authorization consumed", metadata: [
                "conversationId": .string(conversationId.uuidString),
                "operation": .string(operation)
            ])
        }

        return true
    }

    /// Enable or disable auto-approve for a conversation (bypasses all security) - Parameters: - enabled: If true, all operations are automatically authorized without prompts - conversationId: The conversation to enable/disable auto-approve for.
    public func setAutoApprove(_ enabled: Bool, conversationId: UUID) {
        lock.lock()
        defer { lock.unlock() }

        if enabled {
            autoApproveConversations.insert(conversationId)
            logger.warning("Auto-approve ENABLED - all operations authorized without user permission", metadata: [
                "conversationId": .string(conversationId.uuidString)
            ])
        } else {
            autoApproveConversations.remove(conversationId)
            logger.debug("Auto-approve disabled - normal authorization required", metadata: [
                "conversationId": .string(conversationId.uuidString)
            ])
        }
    }

    /// Check if auto-approve is enabled for a conversation - Parameter conversationId: The conversation to check - Returns: True if auto-approve is enabled.
    public func isAutoApproveEnabled(conversationId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return autoApproveConversations.contains(conversationId)
    }

    /// Revoke a specific authorization.
    public func revokeAuthorization(conversationId: UUID, operation: String) {
        lock.lock()
        defer { lock.unlock() }

        authorizations.removeAll { grant in
            grant.conversationId == conversationId && grant.operation == operation
        }

        logger.debug("Authorization revoked", metadata: [
            "conversationId": .string(conversationId.uuidString),
            "operation": .string(operation)
        ])
    }

    /// Revoke all authorizations for a conversation.
    public func revokeAllForConversation(_ conversationId: UUID) {
        lock.lock()
        defer { lock.unlock() }

        let count = authorizations.filter { $0.conversationId == conversationId }.count
        authorizations.removeAll { $0.conversationId == conversationId }

        logger.debug("All authorizations revoked for conversation", metadata: [
            "conversationId": .string(conversationId.uuidString),
            "count": .stringConvertible(count)
        ])
    }

    /// Get all active authorizations for a conversation (for debugging).
    public func getAuthorizations(for conversationId: UUID) -> [AuthorizationGrant] {
        lock.lock()
        defer { lock.unlock() }

        cleanupExpired()
        return authorizations.filter {
            $0.conversationId == conversationId && !$0.consumed && $0.expiresAt > Date()
        }
    }

    /// Clean up expired and consumed authorizations.
    private func cleanupExpired() {
        let now = Date()
        let before = authorizations.count
        authorizations.removeAll { grant in
            grant.expiresAt < now || grant.consumed
        }
        let removed = before - authorizations.count

        if removed > 0 {
            logger.debug("Cleaned up expired/consumed authorizations", metadata: [
                "removed": .stringConvertible(removed)
            ])
        }
    }
}

// MARK: - Supporting Types

/// Represents a temporary authorization grant.
public struct AuthorizationGrant {
    let id: UUID
    let conversationId: UUID
    let operation: String
    let grantedAt: Date
    let expiresAt: Date
    let oneTimeUse: Bool
    var consumed: Bool

    /// Check if this grant is still valid.
    public var isValid: Bool {
        return !consumed && expiresAt > Date()
    }

    /// Time remaining before expiry.
    public var timeRemaining: TimeInterval {
        return expiresAt.timeIntervalSinceNow
    }
}

// MARK: - Helper Methods

extension AuthorizationManager {
    /// Parse user response to detect approval/rejection - Parameter userResponse: The text response from the user - Returns: True if the response indicates approval.
    public static func isApprovalResponse(_ userResponse: String) -> Bool {
        let normalized = userResponse.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        /// Approval keywords.
        let approvalKeywords = [
            "yes", "yep", "yeah", "yup", "y",
            "ok", "okay", "ok!", "k",
            "sure", "certainly", "absolutely",
            "go ahead", "proceed", "continue",
            "approve", "approved", "authorize", "authorized",
            "confirm", "confirmed", "affirmative",
            "do it", "go for it"
        ]

        /// Check for exact matches or if approval keyword is in response.
        for keyword in approvalKeywords {
            if normalized == keyword || normalized.contains(keyword) {
                return true
            }
        }

        return false
    }

    /// Parse user response to detect rejection - Parameter userResponse: The text response from the user - Returns: True if the response indicates rejection.
    public static func isRejectionResponse(_ userResponse: String) -> Bool {
        let normalized = userResponse.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        /// Rejection keywords.
        let rejectionKeywords = [
            "no", "nope", "nah", "n",
            "cancel", "stop", "abort", "halt",
            "don't", "do not", "dont",
            "reject", "rejected", "deny", "denied",
            "negative", "never mind", "nevermind"
        ]

        for keyword in rejectionKeywords {
            if normalized == keyword || normalized.contains(keyword) {
                return true
            }
        }

        return false
    }
}
