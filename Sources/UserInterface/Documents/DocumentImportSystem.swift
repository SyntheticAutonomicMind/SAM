// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Logging
import ConversationEngine

/// Comprehensive Document Import System for SAM Provides native macOS document import capabilities with support for: - PDF documents with text extraction and OCR fallback - Microsoft Office documents (DOCX, Excel spreadsheets) - Text files (TXT, MD, RTF, code files) - Images with OCR text extraction - Drag-and-drop interface integration - File browser integration with native macOS document picker - Seamless Vector RAG Service integration for enhanced search and retrieval Architecture integrates with existing SAM components: - ConversationEngine.VectorRAGService for document processing and embedding - UserInterface components for drag-and-drop and file selection UI - ConfigurationSystem for import preferences and processing options.
@MainActor
public class DocumentImportSystem: ObservableObject {
    private let logger = Logger(label: "com.sam.documents.DocumentImportSystem")

    @Published public var isImporting: Bool = false
    @Published public var importProgress: Double = 0.0
    @Published public var importStatus: String = ""
    @Published public var recentImports: [ImportedDocument] = []
    @Published public var supportedFileTypes: Set<UTType> = []

    /// Integration with existing SAM systems.
    private let vectorRAGService: VectorRAGService?
    private let conversationManager: ConversationManager

    /// Document processing components.
    private let pdfProcessor = PDFDocumentProcessor()
    private let officeProcessor = OfficeDocumentProcessor()
    private let textProcessor = TextDocumentProcessor()
    private let imageProcessor = ImageDocumentProcessor()

    public init(conversationManager: ConversationManager) {
        self.conversationManager = conversationManager
        self.vectorRAGService = conversationManager.vectorRAGService

        /// Verify VectorRAG integration.
        if vectorRAGService != nil {
            logger.debug("DEBUG: DocumentImportSystem initialized WITH VectorRAG service - documents will be searchable")
        } else {
            logger.error("CRITICAL: DocumentImportSystem initialized WITHOUT VectorRAG service - documents will NOT be searchable!")
        }

        setupSupportedFileTypes()
        logger.debug("Document Import System initialized with Vector RAG integration")
    }

    // MARK: - Public API

    /// Import documents from file URLs with full processing pipeline - Parameters: - urls: Array of file URLs to import and process - conversationId: Optional conversation ID for tagging document chunks (conversation-scoped memory) - Returns: Array of successfully imported documents.
    public func importDocuments(from urls: [URL], conversationId: UUID? = nil) async throws -> [ImportedDocument] {
        logger.debug("Starting import of \(urls.count) documents with conversationId: \(conversationId?.uuidString ?? "nil")")

        isImporting = true
        importProgress = 0.0
        importStatus = "Preparing import..."

        var importedDocuments: [ImportedDocument] = []

        defer {
            isImporting = false
            importProgress = 1.0
            importStatus = "Import completed"
        }

        for (index, url) in urls.enumerated() {
            do {
                updateProgress(Double(index) / Double(urls.count), status: "Processing \(url.lastPathComponent)...")

                let (document, extractedContent) = try await processDocument(at: url)
                importedDocuments.append(document)

                /// Integrate with Vector RAG Service for enhanced search capabilities.
                if let vectorRAG = vectorRAGService {
                    logger.debug("DEBUG: VectorRAG service IS available, calling integrateWithVectorRAG for \(document.filename) with conversationId: \(conversationId?.uuidString ?? "nil")")
                    try await integrateWithVectorRAG(document, extractedContent: extractedContent, vectorRAG: vectorRAG, conversationId: conversationId)
                    logger.debug("DEBUG: VectorRAG integration completed for \(document.filename)")
                } else {
                    logger.error("CRITICAL: VectorRAG service is NIL - document will NOT be stored in semantic memory!")
                    logger.error("CRITICAL: Document \(document.filename) (ID: \(document.id)) will not be searchable via memory_search")
                }

                logger.debug("Successfully imported: \(url.lastPathComponent)")

            } catch {
                logger.error("Failed to import \(url.lastPathComponent): \(error)")
                /// Continue with other documents rather than failing entirely.
            }
        }

        recentImports.append(contentsOf: importedDocuments)
        return importedDocuments
    }

    /// Import single document with drag-and-drop support - Parameters: - url: File URL from drag-and-drop or file picker - conversationId: Optional conversation ID for tagging document chunks (conversation-scoped memory) - Returns: Imported document with processing metadata.
    public func importDocument(from url: URL, conversationId: UUID? = nil) async throws -> ImportedDocument {
        return try await importDocuments(from: [url], conversationId: conversationId).first ?? {
            throw DocumentImportError.processingFailed("No documents were successfully imported")
        }()
    }

    /// Check if file type is supported for import - Parameter url: File URL to check - Returns: True if file type is supported.
    public func isFileSupported(_ url: URL) -> Bool {
        guard url.startAccessingSecurityScopedResource() else { return false }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let resourceValues = try url.resourceValues(forKeys: [.contentTypeKey])
            if let contentType = resourceValues.contentType {
                return supportedFileTypes.contains(contentType)
            }
        } catch {
            logger.debug("Could not determine content type for \(url.lastPathComponent)")
        }

        return false
    }

    // MARK: - Internal Processing

    private func setupSupportedFileTypes() {
        supportedFileTypes = [
            /// PDF Documents.
            .pdf,

            /// Microsoft Office Documents.
            UTType("com.microsoft.word.doc") ?? .data,
            UTType("org.openxmlformats.wordprocessingml.document") ?? .data,
            UTType("com.microsoft.excel.xls") ?? .data,
            UTType("org.openxmlformats.spreadsheetml.sheet") ?? .data,

            /// Text Documents.
            .plainText,
            .utf8PlainText,
            .rtf,

            /// Code Files.
            UTType("public.source-code") ?? .data,
            UTType("com.apple.xcode.swift-source") ?? .data,
            UTType("public.python-script") ?? .data,
            UTType("public.javascript-source") ?? .data,

            /// Images (for OCR).
            .jpeg,
            .png,
            .tiff,
            .heic
        ]
    }

    private func processDocument(at url: URL) async throws -> (ImportedDocument, DocumentExtractedContent) {
        guard url.startAccessingSecurityScopedResource() else {
            throw DocumentImportError.accessDenied("Cannot access file: \(url.lastPathComponent)")
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let resourceValues = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .creationDateKey])
        guard let contentType = resourceValues.contentType else {
            throw DocumentImportError.unsupportedFormat("Unknown content type for: \(url.lastPathComponent)")
        }

        let processor: DocumentProcessor

        /// Select appropriate processor based on content type.
        switch contentType {
        case .pdf:
            processor = pdfProcessor

        case _ where contentType.conforms(to: .image):
            processor = imageProcessor

        case _ where isOfficeDocument(contentType):
            processor = officeProcessor

        default:
            processor = textProcessor
        }

        let extractedContent = try await processor.extractContent(from: url, contentType: contentType)

        let document = ImportedDocument(
            id: UUID(),
            url: url,
            filename: url.lastPathComponent,
            contentType: contentType,
            content: extractedContent.text,
            metadata: extractedContent.metadata,
            fileSize: resourceValues.fileSize ?? 0,
            importDate: Date(),
            creationDate: resourceValues.creationDate
        )

        return (document, extractedContent)
    }

    private func integrateWithVectorRAG(_ document: ImportedDocument, extractedContent: DocumentExtractedContent, vectorRAG: VectorRAGService, conversationId: UUID?) async throws {
        logger.debug("DEBUG: integrateWithVectorRAG called for \(document.filename) (ID: \(document.id)) with conversationId: \(conversationId?.uuidString ?? "nil")")
        logger.debug("DEBUG: Document content length: \(document.content.count) characters")

        /// Convert DocumentProcessors.PageContent to VectorRAGService.PageContent if pages exist.
        var ragPages: [ConversationEngine.PageContent]?
        if let docPages = extractedContent.pages, !docPages.isEmpty {
            logger.debug("DEBUG: Document has \(docPages.count) pages - using page-aware chunking")
            ragPages = docPages.map { page in
                ConversationEngine.PageContent(
                    pageNumber: page.pageNumber,
                    text: page.text
                )
            }
        } else {
            logger.debug("DEBUG: Document has no page information - using linear chunking")
        }

        /// Create RAG document for Vector RAG Service integration CRITICAL FIX: Pass conversationId for conversation-scoped memory ENHANCEMENT: Pass pages for page-aware chunking.
        let ragDocument = RAGDocument(
            id: document.id,
            title: document.filename,
            content: document.content,
            type: .text,
            conversationId: conversationId,
            metadata: [
                "filename": document.filename,
                "filePath": document.url.path,
                "fileSize": document.fileSize,
                "importDate": ISO8601DateFormatter().string(from: document.importDate),
                "conversationId": conversationId?.uuidString ?? "global"
            ],
            pages: ragPages
        )

        logger.debug("DEBUG: Calling vectorRAG.ingestDocument with \(document.content.count) chars and conversationId: \(conversationId?.uuidString ?? "nil")")

        /// Ingest into Vector RAG Service and check for failures This is where silent failures were happening - errors thrown but not reported to SAM.
        let result = try await vectorRAG.ingestDocument(ragDocument)

        /// Check for partial failures and throw error if no chunks were stored.
        if result.partialFailure {
            let warningMessage = "Document partially stored: \(result.chunksCreated) chunks succeeded, \(result.failedChunks) chunks failed"
            logger.warning("WARNING: \(warningMessage)")
            logger.warning("WARNING: Error details: \(result.errorDetails ?? "none")")

            /// Throw error so SAM sees the partial failure instead of false success.
            throw DocumentImportError.integrationFailed("\(warningMessage). Details: \(result.errorDetails ?? "none")")
        }

        logger.debug("SUCCESS: Document integrated with Vector RAG: \(result.chunksCreated) chunks created for conversationId: \(conversationId?.uuidString ?? "nil")")
        logger.debug("SUCCESS: Document \(document.filename) (ID: \(document.id)) is now searchable via semantic memory in conversation: \(conversationId?.uuidString ?? "global")")
    }

    private func isOfficeDocument(_ contentType: UTType) -> Bool {
        return contentType.identifier.contains("microsoft") ||
               contentType.identifier.contains("openxmlformats")
    }

    private func updateProgress(_ progress: Double, status: String) {
        Task { @MainActor in
            self.importProgress = progress
            self.importStatus = status
        }
    }
}

// MARK: - Data Models

/// Represents an imported document with processing metadata.
public struct ImportedDocument: Identifiable, Codable {
    public let id: UUID
    public let url: URL
    public let filename: String
    public let contentType: UTType
    public let content: String
    public let metadata: [String: String]
    public let fileSize: Int
    public let importDate: Date
    public let creationDate: Date?

    /// Summary of document for display purposes.
    public var summary: String {
        let preview = content.prefix(200)
        return String(preview) + (content.count > 200 ? "..." : "")
    }

    /// Formatted file size for display.
    public var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }
}

/// Document processing errors.
public enum DocumentImportError: LocalizedError {
    case accessDenied(String)
    case unsupportedFormat(String)
    case processingFailed(String)
    case integrationFailed(String)
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied(let message):
            return "Access denied: \(message)"

        case .unsupportedFormat(let message):
            return "Unsupported format: \(message)"

        case .processingFailed(let message):
            return "Processing failed: \(message)"

        case .integrationFailed(let message):
            return "Integration failed: \(message)"

        case .downloadFailed(let message):
            return "Download failed: \(message)"
        }
    }
}

/// Document processor protocol for different file types.
public protocol DocumentProcessor: Sendable {
    func extractContent(from url: URL, contentType: UTType) async throws -> DocumentExtractedContent
}
