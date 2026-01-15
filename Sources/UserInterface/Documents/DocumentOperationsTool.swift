// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import MCPFramework
import Logging

/// Consolidated Document Operations MCP Tool Combines document_import, document_create, and get_doc_info into a single tool.
public class DocumentOperationsTool: ConsolidatedMCP, ToolDisplayInfoProvider, @unchecked Sendable {
    public let name = "document_operations"
    public let description = """
    Import documents, create formatted files, and get document info.

    OPERATIONS (pass via 'operation' parameter):
    • document_import - Import PDF/DOCX/TXT/MD into conversation memory. Returns extracted styles.
    • document_create - Create formatted DOCX/PDF/PPTX/TXT/Markdown files with explicit style parameters
    • get_doc_info - List imported documents in current conversation

    WORKFLOW FOR PRESERVING STYLES:
    1. Import document → get extracted styles in response
    2. Use those style values as parameters in document_create
    3. Modify any styles you want to change

    WHEN TO USE:
    - Extract content AND formatting from PDFs, Word docs
    - Generate formatted reports with explicit styling
    - Create presentations (PPTX) from markdown
    - Track what documents were imported

    WHEN NOT TO USE:
    - Plain text file reading (use file_operations)
    - Web content (use web_operations)
    - Simple text creation (use file_operations write)

    KEY PARAMETERS:
    • operation: REQUIRED - operation type (see above)
    • path: File path to import (document_import)
    • content: Document content (document_create)
    • format: docx/pdf/pptx/txt/markdown (document_create)
    • font_family, font_size, text_color: Explicit styling (document_create)
    • heading1_size, heading2_size, heading3_size: Heading sizes (document_create)
    • heading_color: Color for headings (document_create)
    • margin_top, margin_bottom, margin_left, margin_right: Page margins (document_create)
    • page_width, page_height: Page dimensions (document_create)
    • template: Template name for PPTX generation (document_create)

    EXAMPLES:
    Import and get styles: {"operation": "document_import", "path": "/docs/report.pdf"}
    Response includes: font_family, font_size, colors, margins, etc.

    Create with extracted styles: {"operation": "document_create", "content": "...", "format": "docx", "font_family": "Calibri", "font_size": 11, "heading1_size": 16}

    Create presentation: {"operation": "document_create", "content": "# Slide 1...", "format": "pptx", "template": "Modern Blue"}
    """

    public var supportedOperations: [String] {
        return [
            "document_import",
            "document_create",
            "get_doc_info"
        ]
    }

    public var parameters: [String: MCPToolParameter] {
        return [
            "operation": MCPToolParameter(
                type: .string,
                description: "Operation to perform",
                required: true,
                enumValues: ["document_import", "document_create", "get_doc_info"]
            ),

            /// Import parameters.
            "path": MCPToolParameter(
                type: .string,
                description: "Path to document file to import (for document_import operation)",
                required: false
            ),
            "tags": MCPToolParameter(
                type: .array,
                description: "Tags to associate with imported document",
                required: false,
                arrayElementType: .string
            ),

            /// Create parameters.
            "content": MCPToolParameter(
                type: .string,
                description: "Content for the document to create (for create operation)",
                required: false
            ),
            "format": MCPToolParameter(
                type: .string,
                description: "Output format: 'docx', 'pdf', 'txt', 'markdown' (for create operation)",
                required: false,
                enumValues: ["docx", "pdf", "txt", "markdown"]
            ),
            "output_path": MCPToolParameter(
                type: .string,
                description: "Path where to save the created document (for create operation)",
                required: false
            )

            /// Get info parameters (minimal - just needs conversationId from context).
        ]
    }

    private let logger = Logger(label: "com.sam.mcp.DocumentOperations")

    /// Delegate tools.
    private var documentImportTool: DocumentImportTool
    private var documentCreateTool: DocumentCreateTool

    public init(documentImportSystem: DocumentImportSystem, documentGenerator: DocumentGenerator) {
        self.documentImportTool = DocumentImportTool(documentImportSystem: documentImportSystem)
        self.documentCreateTool = DocumentCreateTool(documentGenerator: documentGenerator)
        logger.debug("DocumentOperationsTool initialized (consolidated: document_import + document_create + get_doc_info)")

        /// Register with ToolDisplayInfoRegistry for proper progress indicators.
        ToolDisplayInfoRegistry.shared.register("document_operations", provider: DocumentOperationsTool.self)
    }

    // MARK: - Protocol Conformance

    public static func extractDisplayInfo(from arguments: [String: Any]) -> String? {
        /// Extract operation from arguments.
        guard let operation = arguments["operation"] as? String else {
            return nil
        }

        /// Normalize operation name (remove underscores, lowercase).
        let normalizedOp = operation.replacingOccurrences(of: "_", with: "").lowercased()

        switch normalizedOp {
        case "documentimport":
            if let path = arguments["path"] as? String {
                let filename = (path as NSString).lastPathComponent
                return "Importing document: \(filename)"
            }
            return "Importing document"

        case "documentcreate":
            if let filename = arguments["filename"] as? String {
                if let format = arguments["format"] as? String {
                    return "Creating \(format.uppercased()): \(filename)"
                }
                return "Creating document: \(filename)"
            }
            if let outputPath = arguments["output_path"] as? String {
                let filename = (outputPath as NSString).lastPathComponent
                return "Creating document: \(filename)"
            }
            if let format = arguments["format"] as? String {
                return "Creating \(format.uppercased()) document"
            }
            return "Creating document"

        case "getdocinfo":
            if let filePath = (arguments["path"] as? String) ?? (arguments["filePath"] as? String) {
                let filename = (filePath as NSString).lastPathComponent
                return "Getting info: \(filename)"
            }
            return "Getting document info"

        default:
            return nil
        }
    }

    public func routeOperation(
        _ operation: String,
        parameters: [String: Any],
        context: MCPExecutionContext
    ) async -> MCPToolResult {
        logger.debug("DocumentOperationsTool routing to operation: \(operation)")

        /// Validate parameters before routing.
        if let validationError = validateParameters(operation: operation, parameters: parameters) {
            return validationError
        }

        switch operation {
        case "document_import":
            return await handleImport(parameters: parameters, context: context)

        case "document_create":
            return await handleCreate(parameters: parameters, context: context)

        case "get_doc_info":
            return await handleGetInfo(parameters: parameters, context: context)

        default:
            return operationError(operation, message: "Unknown operation")
        }
    }

    // MARK: - Parameter Validation

    private func validateParameters(operation: String, parameters: [String: Any]) -> MCPToolResult? {
        switch operation {
        case "document_import":
            guard parameters["path"] is String else {
                return operationError(operation, message: """
                    Missing required parameter 'path'.

                    Usage: {"operation": "document_import", "path": "/path/to/document.pdf"}
                    Example: {"operation": "document_import", "path": "/Users/username/Desktop/report.docx"}
                    """)
            }

        case "document_create":
            guard parameters["content"] is String else {
                return operationError(operation, message: """
                    Missing required parameter 'content'.

                    Usage: {"operation": "document_create", "content": "document text", "format": "docx|pdf|txt|markdown"}
                    Example: {"operation": "document_create", "content": "Summary...", "format": "docx"}
                    """)
            }
            guard parameters["format"] is String else {
                return operationError(operation, message: """
                    Missing required parameter 'format'.

                    Valid formats: 'docx', 'pdf', 'txt', 'markdown'
                    Example: {"operation": "document_create", "content": "text", "format": "docx"}
                    """)
            }

        default:
            break
        }

        return nil
    }

    // MARK: - Import Operation

    @MainActor
    private func handleImport(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        /// Map consolidated parameter name "path" to internal tool's expected "url" Also handle conversion of plain file paths to file:// URLs.
        var mappedParameters = parameters
        if let path = parameters["path"] as? String {
            /// Convert plain file paths to file:// URLs if needed.
            let urlString: String
            if path.hasPrefix("http://") || path.hasPrefix("https://") || path.hasPrefix("file://") {
                /// Already a proper URL.
                urlString = path
            } else {
                /// Plain file path - resolve against working directory to get absolute path
                /// This ensures relative paths like "book/file.md" are resolved correctly
                /// before being converted to file:// URLs.
                let resolvedPath = MCPAuthorizationGuard.resolvePath(path, workingDirectory: context.workingDirectory)
                /// Create file:// URL with absolute path (will have 3 slashes: file:///...)
                urlString = "file://\(resolvedPath)"
            }

            mappedParameters["url"] = urlString
            mappedParameters.removeValue(forKey: "path")
        }

        /// Delegate to DocumentImportTool implementation.
        return await documentImportTool.execute(parameters: mappedParameters, context: context)
    }

    // MARK: - Create Operation

    @MainActor
    private func handleCreate(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        /// Map consolidated parameters to DocumentCreateTool's expected format.
        var mappedParameters = parameters

        /// DocumentCreateTool requires 'filename' parameter If not provided, generate from output_path or use default.
        if mappedParameters["filename"] == nil {
            if let outputPath = mappedParameters["output_path"] as? String {
                /// Extract filename from output_path.
                let filename = (outputPath as NSString).lastPathComponent
                /// Remove extension if present (DocumentCreateTool adds it based on format).
                let filenameWithoutExt = (filename as NSString).deletingPathExtension
                mappedParameters["filename"] = filenameWithoutExt.isEmpty ? "document" : filenameWithoutExt

                /// Extract directory path (if any) and set as output_path.
                let dirPath = (outputPath as NSString).deletingLastPathComponent
                if !dirPath.isEmpty && dirPath != "." {
                    mappedParameters["output_path"] = dirPath
                } else {
                    mappedParameters.removeValue(forKey: "output_path")
                }
            } else {
                /// No filename or output_path provided - use default.
                mappedParameters["filename"] = "document"
            }
        }

        /// Delegate to DocumentCreateTool implementation.
        return await documentCreateTool.execute(parameters: mappedParameters, context: context)
    }

    // MARK: - Get Info Operation

    @MainActor
    private func handleGetInfo(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        /// Map consolidated parameter name "path" to internal tool's expected "file_path" GetDocInfoTool handles tilde expansion internally, so just pass the path.
        var mappedParameters = parameters
        if let path = parameters["path"] as? String {
            mappedParameters["file_path"] = path
            mappedParameters.removeValue(forKey: "path")
        }

        /// Create GetDocInfoTool instance for this operation.
        let getDocInfoTool = GetDocInfoTool()
        return await getDocInfoTool.execute(parameters: mappedParameters, context: context)
    }
}
