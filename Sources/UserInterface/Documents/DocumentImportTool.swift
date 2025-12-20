// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import MCPFramework
import Logging

/// MCP tool for document import capabilities Thin wrapper around DocumentImportSystem that provides MCP interface for importing documents with automatic memory integration ARCHITECTURE: - This tool is a thin MCP wrapper that delegates to DocumentImportSystem - DocumentImportSystem handles all document processing (PDF, DOCX, TXT, RTF, images) - Automatic VectorRAG integration ensures content is stored in memory - Supports both remote URLs (http://, https://) and local files (file://).
public class DocumentImportTool: MCPTool, @unchecked Sendable {
    public let name = "document_import"
    public let description = "Import documents (PDF, DOCX, XLSX, XLS, TXT, RTF, images) from URLs or local files and store in conversation memory. Supports remote (http://, https://) and local (file://) paths. Excel spreadsheets (XLSX, XLS) are fully supported - text and data will be extracted. Automatically extracts text, stores in memory database, and returns document ID for future reference."

    private let documentImportSystem: DocumentImportSystem
    private let logger = Logger(label: "com.sam.mcp.DocumentImport")

    /// Use ephemeral URLSession with timeout for document downloads
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60.0  // Allow 60s for document download
        config.timeoutIntervalForResource = 300.0 // Allow 5min for large documents
        config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }()

    public var parameters: [String: MCPToolParameter] {
        [
            "url": MCPToolParameter(
                type: .string,
                description: "URL or file path of the document. Supports http://, https:// for remote files, or file:/// for local files (e.g., file:///Users/user/document.pdf)",
                required: true
            ),
            "max_length": MCPToolParameter(
                type: .integer,
                description: "Maximum length of content to return in response (default: 500 chars). Full content is always stored in memory regardless of this limit. Use memory_search to query document content.",
                required: false
            )
        ]
    }

    public init(documentImportSystem: DocumentImportSystem) {
        self.documentImportSystem = documentImportSystem
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        logger.debug("Executing document import tool")

        /// Validate URL parameter.
        guard let urlString = parameters["url"] as? String,
              !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: "Required parameter 'url' is missing or invalid. Must be a valid URL (http://, https://) or file path (file:///).", mimeType: "text/plain"),
                toolName: name
            )
        }

        /// Create URL with proper handling of percent-encoded paths For file:// URLs, we need to decode the path to access actual files.
        guard let url = URL(string: urlString) else {
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: "Invalid URL format: '\(urlString)'. Must be a valid URL (http://, https://) or file path (file:///).", mimeType: "text/plain"),
                toolName: name
            )
        }

        /// For file URLs with percent encoding (e.g., file:///path/file%20name.pdf), create a new URL using the decoded path so file system can find it.
        let finalURL: URL
        var tempFileToCleanup: URL?

        if url.isFileURL {
            /// Use path(percentEncoded: false) to get decoded path, then create file URL This converts "file:///path/file%20name.pdf" → "/path/file name.pdf" → proper file URL.
            var decodedPath = url.path(percentEncoded: false)
            logger.debug("Decoded file URL: '\(urlString)' → '\(decodedPath)'")

            /// Handle malformed URLs like "file://filename" (missing third slash)
            /// In this case, the filename is interpreted as the host component and path is empty
            /// Try to recover by using the host as filename and prepending working directory
            if decodedPath.isEmpty {
                if let host = url.host, !host.isEmpty, let workingDir = context.workingDirectory {
                    /// LLM passed "file://simple-budget.xlsx" - host is "simple-budget.xlsx", path is empty
                    /// Try to find the file in the working directory
                    let recoveredPath = (workingDir as NSString).appendingPathComponent(host)
                    logger.info("Recovering malformed file URL: '\(urlString)' → attempting '\(recoveredPath)'")

                    if FileManager.default.fileExists(atPath: recoveredPath) {
                        decodedPath = recoveredPath
                        logger.info("File found at recovered path: '\(recoveredPath)'")
                    } else {
                        /// File not found in working directory either
                        return MCPToolResult(
                            success: false,
                            output: MCPOutput(content: "Invalid file URL format: '\(urlString)'. The filename '\(host)' was not found in the working directory '\(workingDir)'. File URLs must use triple slash format: file:///path/to/file. Example: file:///Users/username/Documents/file.pdf", mimeType: "text/plain"),
                            toolName: name
                        )
                    }
                } else {
                    /// No host or no working directory - can't recover
                    return MCPToolResult(
                        success: false,
                        output: MCPOutput(content: "Invalid file URL format: '\(urlString)'. File URLs must use triple slash format: file:///path/to/file. Example: file:///Users/username/Documents/file.pdf", mimeType: "text/plain"),
                        toolName: name
                    )
                }
            }

            finalURL = URL(fileURLWithPath: decodedPath)

            /// AUTHORIZATION CHECK: For local files, verify path is within workspace or get user approval
            let authResult = MCPAuthorizationGuard.checkPathAuthorization(
                path: decodedPath,
                workingDirectory: context.workingDirectory,
                conversationId: context.conversationId,
                operation: "document_import",
                isUserInitiated: context.isUserInitiated
            )

            switch authResult {
            case .allowed(let reason):
                logger.debug("Document import authorized: \(reason)")

            case .denied(let reason):
                return MCPToolResult(
                    success: false,
                    output: MCPOutput(content: "Document import denied: \(reason)", mimeType: "text/plain"),
                    toolName: name
                )

            case .requiresAuthorization(let reason):
                let authError = MCPAuthorizationGuard.authorizationError(
                    operation: "document_import",
                    reason: reason,
                    suggestedPrompt: "May I import document from \(decodedPath)?"
                )
                if let errorMsg = authError["error"] as? String {
                    return MCPToolResult(
                        success: false,
                        output: MCPOutput(content: errorMsg, mimeType: "text/plain"),
                        toolName: name
                    )
                }
                return MCPToolResult(
                    success: false,
                    output: MCPOutput(content: "Authorization required for path: \(decodedPath)", mimeType: "text/plain"),
                    toolName: name
                )
            }
        } else {
            /// Remote URLs (http/https) - download to temporary location first.
            logger.debug("Downloading remote document from: \(urlString)")
            do {
                let (downloadedURL, _) = try await session.download(from: url)

                /// Move to temp location with original filename.
                let tempDir = FileManager.default.temporaryDirectory
                let filename = url.lastPathComponent
                let tempFileURL = tempDir.appendingPathComponent(filename)

                /// Remove existing temp file if it exists.
                if FileManager.default.fileExists(atPath: tempFileURL.path) {
                    try? FileManager.default.removeItem(at: tempFileURL)
                }

                try FileManager.default.moveItem(at: downloadedURL, to: tempFileURL)
                finalURL = tempFileURL
                tempFileToCleanup = tempFileURL
                logger.debug("Downloaded remote document to: \(tempFileURL.path)")
            } catch {
                logger.error("Failed to download remote document: \(error)")
                return MCPToolResult(
                    success: false,
                    output: MCPOutput(content: "Failed to download document from URL: \(error.localizedDescription)", mimeType: "text/plain"),
                    toolName: name
                )
            }
        }

        let maxLength = parameters["max_length"] as? Int ?? 500

        logger.debug("Document import request: url='\(urlString)', maxLength=\(maxLength), conversationId=\(context.conversationId?.uuidString ?? "nil")")

        do {
            /// Delegate to DocumentImportSystem for full processing pipeline CRITICAL: Pass conversationId from context for conversation-scoped memory This ensures documents are tagged with the conversation they belong to.
            let importedDocument = try await documentImportSystem.importDocument(
                from: finalURL,
                conversationId: context.conversationId
            )

            /// Clean up temporary downloaded file if it exists.
            if let tempFile = tempFileToCleanup {
                try? FileManager.default.removeItem(at: tempFile)
                logger.debug("Cleaned up temporary file: \(tempFile.path)")
            }

            logger.debug("Document imported successfully: \(importedDocument.id), \(importedDocument.content.count) chars, conversationId: \(context.conversationId?.uuidString ?? "nil")")

            /// Record import for reminder injection so agent doesn't re-import.
            if let conversationId = context.conversationId {
                DocumentImportReminderInjector.shared.recordImport(
                    conversationId: conversationId,
                    filename: importedDocument.filename,
                    documentId: importedDocument.id.uuidString,
                    contentLength: importedDocument.content.count
                )
            }

            /// Create success response with document info.
            return createSuccessResult(
                document: importedDocument,
                maxLength: maxLength,
                url: urlString
            )

        } catch let error as DocumentImportError {
            /// Clean up temporary downloaded file if it exists.
            if let tempFile = tempFileToCleanup {
                try? FileManager.default.removeItem(at: tempFile)
                logger.debug("Cleaned up temporary file after error: \(tempFile.path)")
            }

            logger.error("Document import failed: \(error)")
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: "Document import failed: \(error.localizedDescription)", mimeType: "text/plain"),
                toolName: name
            )
        } catch {
            /// Clean up temporary downloaded file if it exists.
            if let tempFile = tempFileToCleanup {
                try? FileManager.default.removeItem(at: tempFile)
                logger.debug("Cleaned up temporary file after error: \(tempFile.path)")
            }

            logger.error("Document import failed with unexpected error: \(error)")
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: "Document import failed: \(error.localizedDescription)", mimeType: "text/plain"),
                toolName: name
            )
        }
    }

    // MARK: - Helper Methods

    /// Creates a success result with document information, preview, and extracted formatting styles.
    private func createSuccessResult(document: ImportedDocument, maxLength: Int, url: String) -> MCPToolResult {
        /// Truncate content for response if needed.
        let contentPreview = document.content.count > maxLength
            ? String(document.content.prefix(maxLength)) + "\n\n[Content truncated - \(document.content.count) total chars stored in memory. Use memory_search to query document content.]"
            : document.content

        /// Extract basic formatting information for agent to use
        let extractedStyles = extractFormattingInfo(from: document)

        var resultData: [String: Any] = [
            "type": "document_import",
            "success": true,
            "document_id": document.id.uuidString,
            "filename": document.filename,
            "source_url": url,
            "content_type": document.contentType.identifier,
            "file_size": document.fileSize,
            "full_content_length": document.content.count,
            "preview_length": contentPreview.count,
            "import_date": ISO8601DateFormatter().string(from: document.importDate),
            "memory_stored": true,
            "content_preview": contentPreview
        ]

        // Add extracted styles if available
        if let styles = extractedStyles {
            resultData["extracted_styles"] = styles
        }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: resultData, options: .prettyPrinted)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? contentPreview

            return MCPToolResult(
                success: true,
                output: MCPOutput(content: jsonString, mimeType: "application/json"),
                toolName: name
            )
        } catch {
            /// Fallback to plain text if JSON serialization fails.
            var fallbackMessage = """
            Document imported successfully!

            Document ID: \(document.id.uuidString)
            Filename: \(document.filename)
            Size: \(document.fileSize) bytes
            Content length: \(document.content.count) characters
            Stored in memory: Yes
            """

            if let styles = extractedStyles {
                fallbackMessage += "\n\nExtracted Styles: \(styles)"
            }

            fallbackMessage += "\n\nContent Preview:\n\(contentPreview)"

            return MCPToolResult(
                success: true,
                output: MCPOutput(content: fallbackMessage, mimeType: "text/plain"),
                toolName: name
            )
        }
    }

    /// Extract basic formatting information from document for agent to use when recreating
    private func extractFormattingInfo(from document: ImportedDocument) -> [String: Any]? {
        // Note: This is a simplified extraction. Real implementation would analyze
        // the actual document structure (PDF metadata, DOCX styles.xml, etc.)
        // For now, return sensible defaults that agents can override

        var styles: [String: Any] = [
            "font_family": "Helvetica",  // Default, can be extracted from PDF/DOCX
            "font_size": 12,
            "text_color": "#000000",
            "heading1_size": 24,
            "heading2_size": 20,
            "heading3_size": 16,
            "heading_color": "#000000",
            "margin_top": 72,      // 1 inch
            "margin_bottom": 72,
            "margin_left": 72,
            "margin_right": 72,
            "page_width": 612,     // US Letter
            "page_height": 792,
            "line_spacing": 1.15
        ]

        // Add note to agent
        styles["_note"] = "These are default values. Modify as needed for your document."

        return styles
    }
}
