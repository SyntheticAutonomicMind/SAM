// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import AppKit
import PDFKit
import ConfigurationSystem
import ConversationEngine
import Logging

/// Service for printing conversations via PDF generation
public class PrintService {
    private static let logger = Logger(label: "com.sam.documents.PrintService")

    /// Print a full conversation via WKWebView HTML rendering
    @MainActor
    public static func printConversation(
        conversation: ConversationModel,
        messages: [EnhancedMessage]? = nil
    ) {
        let messagesToPrint = messages ?? conversation.messages
        logger.info("Printing conversation via WKWebView: \(conversation.title), \(messagesToPrint.count) messages")

        let msgTuples = messagesToPrint.map { msg in
            (content: msg.content, isFromUser: msg.isFromUser)
        }

        WKWebViewPrintService.printConversation(
            messages: msgTuples,
            title: conversation.title
        )
    }

    /// Show error alert
    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Print Failed"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }
}
