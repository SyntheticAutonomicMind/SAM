// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Global notification system for tool execution events Enables tools to communicate with the UI layer without direct coupling.
public class ToolNotificationCenter {

    /// Singleton instance for global access.
    public nonisolated(unsafe) static let shared = ToolNotificationCenter()

    /// Internal NotificationCenter for event distribution.
    private let notificationCenter = NotificationCenter.default

    private init() {}

    // MARK: - Notification Names

    /// User input required notification Posted when tool needs user collaboration UserInfo keys: "toolCallId", "prompt", "context", "conversationId".
    public static let userInputRequiredNotification = Notification.Name("com.sam.tool.userInputRequired")

    /// User response received notification Posted when user submits collaboration response UserInfo keys: "toolCallId", "userInput", "conversationId".
    public static let userResponseReceivedNotification = Notification.Name("com.sam.tool.userResponseReceived")

    /// Tool progress update notification Posted for long-running operations UserInfo keys: "toolCallId", "progress", "message".
    public static let toolProgressNotification = Notification.Name("com.sam.tool.progress")

    /// Tool error notification Posted when tool encounters non-fatal error needing user attention UserInfo keys: "toolCallId", "error", "recoverable".
    public static let toolErrorNotification = Notification.Name("com.sam.tool.error")

    /// Image display notification Posted when image_generation tool completes successfully UserInfo keys: "toolCallId", "imagePaths", "prompt", "conversationId".
    public static let imageDisplayNotification = Notification.Name("com.sam.tool.imageDisplay")

    // MARK: - Post Notifications

    /// Post user input required notification.
    public func postUserInputRequired(
        toolCallId: String,
        prompt: String,
        context: String? = nil,
        conversationId: UUID? = nil
    ) {
        var userInfo: [String: Any] = [
            "toolCallId": toolCallId,
            "prompt": prompt
        ]

        if let context = context {
            userInfo["context"] = context
        }

        if let conversationId = conversationId {
            userInfo["conversationId"] = conversationId.uuidString
        }

        notificationCenter.post(
            name: Self.userInputRequiredNotification,
            object: nil,
            userInfo: userInfo
        )
    }

    /// Post user response received notification.
    public func postUserResponseReceived(
        toolCallId: String,
        userInput: String,
        conversationId: UUID? = nil
    ) {
        let logger = Logger(label: "com.sam.mcp.ToolNotificationCenter")
        logger.debug("COLLAB_DEBUG: Posting userResponseReceived notification", metadata: [
            "toolCallId": .string(toolCallId),
            "userInputLength": .stringConvertible(userInput.count),
            "conversationId": .string(conversationId?.uuidString ?? "nil")
        ])
        
        var userInfo: [String: Any] = [
            "toolCallId": toolCallId,
            "userInput": userInput
        ]

        if let conversationId = conversationId {
            userInfo["conversationId"] = conversationId.uuidString
        }

        notificationCenter.post(
            name: Self.userResponseReceivedNotification,
            object: nil,
            userInfo: userInfo
        )
        
        logger.debug("COLLAB_DEBUG: Notification posted successfully")
    }

    /// Post tool progress update.
    public func postToolProgress(
        toolCallId: String,
        progress: Double,
        message: String
    ) {
        notificationCenter.post(
            name: Self.toolProgressNotification,
            object: nil,
            userInfo: [
                "toolCallId": toolCallId,
                "progress": progress,
                "message": message
            ]
        )
    }

    /// Post tool error notification.
    public func postToolError(
        toolCallId: String,
        error: String,
        recoverable: Bool
    ) {
        notificationCenter.post(
            name: Self.toolErrorNotification,
            object: nil,
            userInfo: [
                "toolCallId": toolCallId,
                "error": error,
                "recoverable": recoverable
            ]
        )
    }

    /// Post image display notification.
    public func postImageDisplay(
        toolCallId: String,
        imagePaths: [String],
        prompt: String,
        conversationId: UUID? = nil
    ) {
        var userInfo: [String: Any] = [
            "toolCallId": toolCallId,
            "imagePaths": imagePaths,
            "prompt": prompt
        ]

        if let conversationId = conversationId {
            userInfo["conversationId"] = conversationId.uuidString
        }

        notificationCenter.post(
            name: Self.imageDisplayNotification,
            object: nil,
            userInfo: userInfo
        )
    }

    // MARK: - Observe Notifications

    /// Observe user input required notifications.
    public func observeUserInputRequired(
        using block: @escaping @Sendable (String, String, String?, UUID?) -> Void
    ) -> NSObjectProtocol {
        return notificationCenter.addObserver(
            forName: Self.userInputRequiredNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let userInfo = notification.userInfo,
                  let toolCallId = userInfo["toolCallId"] as? String,
                  let prompt = userInfo["prompt"] as? String else {
                return
            }

            let context = userInfo["context"] as? String
            let conversationId: UUID? = {
                if let idString = userInfo["conversationId"] as? String {
                    return UUID(uuidString: idString)
                }
                return nil
            }()

            block(toolCallId, prompt, context, conversationId)
        }
    }

    /// Observe user response received notifications.
    public func observeUserResponseReceived(
        using block: @escaping @Sendable (String, String, UUID?) -> Void
    ) -> NSObjectProtocol {
        return notificationCenter.addObserver(
            forName: Self.userResponseReceivedNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let userInfo = notification.userInfo,
                  let toolCallId = userInfo["toolCallId"] as? String,
                  let userInput = userInfo["userInput"] as? String else {
                return
            }

            let conversationId: UUID? = {
                if let idString = userInfo["conversationId"] as? String {
                    return UUID(uuidString: idString)
                }
                return nil
            }()

            block(toolCallId, userInput, conversationId)
        }
    }

    /// Observe tool progress notifications.
    public func observeToolProgress(
        using block: @escaping @Sendable (String, Double, String) -> Void
    ) -> NSObjectProtocol {
        return notificationCenter.addObserver(
            forName: Self.toolProgressNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let userInfo = notification.userInfo,
                  let toolCallId = userInfo["toolCallId"] as? String,
                  let progress = userInfo["progress"] as? Double,
                  let message = userInfo["message"] as? String else {
                return
            }

            block(toolCallId, progress, message)
        }
    }

    /// Observe tool error notifications.
    public func observeToolError(
        using block: @escaping @Sendable (String, String, Bool) -> Void
    ) -> NSObjectProtocol {
        return notificationCenter.addObserver(
            forName: Self.toolErrorNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let userInfo = notification.userInfo,
                  let toolCallId = userInfo["toolCallId"] as? String,
                  let error = userInfo["error"] as? String,
                  let recoverable = userInfo["recoverable"] as? Bool else {
                return
            }

            block(toolCallId, error, recoverable)
        }
    }

    /// Observe image display notifications.
    public func observeImageDisplay(
        using block: @escaping @Sendable (String, [String], String, UUID?) -> Void
    ) -> NSObjectProtocol {
        return notificationCenter.addObserver(
            forName: Self.imageDisplayNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let userInfo = notification.userInfo,
                  let toolCallId = userInfo["toolCallId"] as? String,
                  let imagePaths = userInfo["imagePaths"] as? [String],
                  let prompt = userInfo["prompt"] as? String else {
                return
            }

            let conversationId: UUID? = {
                if let idString = userInfo["conversationId"] as? String {
                    return UUID(uuidString: idString)
                }
                return nil
            }()

            block(toolCallId, imagePaths, prompt, conversationId)
        }
    }

    /// Remove observer.
    public func removeObserver(_ observer: NSObjectProtocol) {
        notificationCenter.removeObserver(observer)
    }
}
