// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Injects document import reminders into agent context.
/// Tells agents what documents have been imported so they search memory instead of re-importing.
public class DocumentImportReminderInjector {
    private let logger = Logging.Logger(label: "com.sam.DocumentImportReminderInjector")

    /// Track imported documents per conversation.
    private var importedDocuments: [UUID: [ImportedDocInfo]] = [:]
    private let lock = NSLock()

    public nonisolated(unsafe) static let shared = DocumentImportReminderInjector()

    /// Simple struct to track imported document info.
    public struct ImportedDocInfo {
        public let filename: String
        public let documentId: String
        public let importDate: Date
        public let contentLength: Int

        public init(filename: String, documentId: String, importDate: Date = Date(), contentLength: Int = 0) {
            self.filename = filename
            self.documentId = documentId
            self.importDate = importDate
            self.contentLength = contentLength
        }
    }

    private init() {
        logger.debug("DocumentImportReminderInjector initialized")
    }

    /// Record that a document was imported for a conversation.
    public func recordImport(
        conversationId: UUID,
        filename: String,
        documentId: String,
        contentLength: Int = 0
    ) {
        lock.lock()
        defer { lock.unlock() }

        let info = ImportedDocInfo(
            filename: filename,
            documentId: documentId,
            importDate: Date(),
            contentLength: contentLength
        )

        if importedDocuments[conversationId] == nil {
            importedDocuments[conversationId] = []
        }

        /// Avoid duplicates.
        if !importedDocuments[conversationId]!.contains(where: { $0.filename == filename }) {
            importedDocuments[conversationId]!.append(info)
            logger.info("Recorded document import: \(filename) for conversation \(conversationId.uuidString.prefix(8))")
        }
    }

    /// Get the count of imported documents for a conversation.
    public func getImportedCount(for conversationId: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return importedDocuments[conversationId]?.count ?? 0
    }

    /// Check if reminder should be injected.
    /// Always inject if there are imported documents.
    public func shouldInjectReminder(conversationId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (importedDocuments[conversationId]?.count ?? 0) > 0
    }

    /// Format document import reminder for injection into system prompt.
    /// Returns nil if no documents imported.
    /// NOTE: Returns PLAIN content WITHOUT <system-reminder> tags.
    /// The caller is responsible for wrapping with appropriate tags based on model type.
    public func formatDocumentReminder(conversationId: UUID) -> String? {
        lock.lock()
        let docs = importedDocuments[conversationId] ?? []
        lock.unlock()

        guard !docs.isEmpty else {
            return nil
        }

        var reminder = """
        IMPORTED DOCUMENTS IN THIS CONVERSATION:
        The following documents have already been imported into memory. DO NOT re-import them.
        Use memory_operations with operation=search_memory to query their content instead.

        """

        for doc in docs {
            let sizeInfo = doc.contentLength > 0 ? " (\(doc.contentLength) chars)" : ""
            reminder += "• \(doc.filename)\(sizeInfo) - ID: \(doc.documentId.prefix(8))\n"
        }

        reminder += """

        To search these documents, use:
        memory_operations(operation: "search_memory", query: "your search query", similarity_threshold: "0.2")
        """

        return reminder
    }

    /// Clear imported documents tracking for a conversation.
    public func clearTracking(for conversationId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        importedDocuments.removeValue(forKey: conversationId)
        logger.debug("Cleared document import tracking for conversation \(conversationId.uuidString.prefix(8))")
    }

    /// Get list of imported document filenames for a conversation.
    public func getImportedFilenames(for conversationId: UUID) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return importedDocuments[conversationId]?.map { $0.filename } ?? []
    }
}
