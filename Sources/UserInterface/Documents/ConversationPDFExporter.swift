// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import PDFKit
import AppKit
import ConfigurationSystem
import ConversationEngine
import Logging

/// Service for exporting full conversations to PDF
/// Generates professional-quality PDF documents with continuous message flow and proper pagination
public class ConversationPDFExporter {
    private let logger = Logger(label: "com.sam.documents.ConversationPDFExporter")

    /// Generate a professional PDF from a conversation with continuous message flow
    /// - Parameters:
    ///   - conversation: The conversation to export
    ///   - messages: The messages to include (defaults to conversation.messages)
    /// - Returns: URL to the generated PDF file
    @MainActor
    public func generatePDF(
        conversation: ConversationModel,
        messages: [EnhancedMessage]? = nil
    ) async throws -> URL {
        let messagesToExport = (messages ?? conversation.messages)
            .filter { !$0.isToolMessage }  // Skip tool messages for cleaner export
            .sorted { $0.timestamp < $1.timestamp }

        logger.info("Generating conversation PDF using UnifiedPDFGenerator: \(messagesToExport.count) messages")

        // Use UnifiedPDFGenerator for reliable PDF generation
        return try await UnifiedPDFGenerator.generatePDF(
            messages: messagesToExport,
            conversationTitle: conversation.title,
            modelName: nil,
            includeHeaders: true  // Show message role headers for conversations
        )
    }
}


// MARK: - Error Types

public enum ConversationExportError: Error, LocalizedError {
    case pdfCreationFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .pdfCreationFailed(let message):
            return "PDF creation failed: \(message)"
        case .writeFailed(let message):
            return "Write failed: \(message)"
        }
    }
}
