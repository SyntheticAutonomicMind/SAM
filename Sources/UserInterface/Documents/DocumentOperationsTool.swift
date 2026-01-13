// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import MCPFramework
import Logging
import Training

/// Consolidated Document Operations MCP Tool Combines document_import, document_create, and get_doc_info into a single tool.
public class DocumentOperationsTool: ConsolidatedMCP, ToolDisplayInfoProvider, @unchecked Sendable {
    public let name = "document_operations"
    public let description = """
    Import documents, create formatted files, and get document info.

    OPERATIONS (pass via 'operation' parameter):
    • document_import - Import PDF/DOCX/TXT/MD into conversation memory. Returns extracted styles.
    • document_create - Create formatted DOCX/PDF/PPTX/TXT/Markdown files with explicit style parameters
    • get_doc_info - List imported documents in current conversation
    • ingest_codebase - Recursively import all code files from directory into memory (optionally export JSONL)

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
            "get_doc_info",
            "ingest_codebase"
        ]
    }

    public var parameters: [String: MCPToolParameter] {
        return [
            "operation": MCPToolParameter(
                type: .string,
                description: "Operation to perform",
                required: true,
                enumValues: ["document_import", "document_create", "get_doc_info", "ingest_codebase"]
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
            ),

            /// Ingest codebase parameters.
            "directory_path": MCPToolParameter(
                type: .string,
                description: "Root directory to recursively scan for code files (for ingest_codebase operation)",
                required: false
            ),
            "file_patterns": MCPToolParameter(
                type: .array,
                description: "File patterns to match (e.g., ['*.swift', '*.md']). Default: common code file extensions",
                required: false,
                arrayElementType: .string
            ),
            "max_files": MCPToolParameter(
                type: .integer,
                description: "Maximum number of files to ingest (safety limit, default: 500)",
                required: false
            ),
            "export_training": MCPToolParameter(
                type: .boolean,
                description: "Whether to also export ingested files as JSONL training data (default: false)",
                required: false
            ),
            "export_path": MCPToolParameter(
                type: .string,
                description: "Path where to save JSONL training file if export_training is true",
                required: false
            )

            /// Get info parameters (minimal - just needs conversationId from context).
        ]
    }

    private let logger = Logger(label: "com.sam.mcp.DocumentOperations")

    /// Delegate tools.
    private var documentImportTool: DocumentImportTool
    private var documentCreateTool: DocumentCreateTool
    
    /// Store reference to DocumentImportSystem for ingest_codebase operation
    private let documentImportSystem: DocumentImportSystem

    public init(documentImportSystem: DocumentImportSystem, documentGenerator: DocumentGenerator) {
        self.documentImportSystem = documentImportSystem
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

        case "ingestcodebase":
            if let dirPath = arguments["directory_path"] as? String {
                let dirname = (dirPath as NSString).lastPathComponent
                return "Ingesting codebase: \(dirname)"
            }
            return "Ingesting codebase"

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

        case "ingest_codebase":
            return await handleIngestCodebase(parameters: parameters, context: context)

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

        case "ingest_codebase":
            guard parameters["directory_path"] is String else {
                return operationError(operation, message: """
                    Missing required parameter 'directory_path'.

                    Usage: {"operation": "ingest_codebase", "directory_path": "/path/to/code"}
                    Optional: "file_patterns": ["*.swift"], "max_files": 500, "export_training": true, "export_path": "/path/output.jsonl"
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

    // MARK: - Ingest Codebase Operation

    @MainActor
    private func handleIngestCodebase(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        guard let directoryPath = parameters["directory_path"] as? String else {
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: "Missing required parameter 'directory_path'", mimeType: "text/plain"),
                toolName: name
            )
        }

        /// Resolve directory path against working directory
        let resolvedPath = MCPAuthorizationGuard.resolvePath(directoryPath, workingDirectory: context.workingDirectory)
        let directoryURL = URL(fileURLWithPath: resolvedPath)

        /// Verify directory exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: "Directory not found or is not a directory: \(resolvedPath)", mimeType: "text/plain"),
                toolName: name
            )
        }

        /// Get parameters
        let maxFiles = parameters["max_files"] as? Int ?? 500
        let exportTraining = parameters["export_training"] as? Bool ?? false
        let exportPath = parameters["export_path"] as? String

        /// Get file patterns or use defaults
        let defaultPatterns = ["*.swift", "*.md", "*.py", "*.js", "*.ts", "*.go", "*.rs", "*.cpp", "*.c", "*.h", "*.java", "*.kt", "*.rb", "*.php", "*.txt"]
        let filePatterns: [String]
        if let patterns = parameters["file_patterns"] as? [String], !patterns.isEmpty {
            filePatterns = patterns
        } else {
            filePatterns = defaultPatterns
        }

        logger.info("Ingesting codebase from \(resolvedPath) with patterns: \(filePatterns)")

        /// Scan directory recursively
        var fileURLs: [URL] = []
        let fileManager = FileManager.default
        let excludedDirs: Set<String> = [".git", ".build", "build", ".swiftpm", "node_modules", ".DS_Store", "DerivedData", ".xcode", "xcuserdata", ".vscode"]

        func scanDirectory(_ url: URL) {
            guard fileURLs.count < maxFiles else { return }

            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                logger.warning("Failed to create enumerator for \(url.path)")
                return
            }

            for case let fileURL as URL in enumerator {
                guard fileURLs.count < maxFiles else { break }

                /// Check if should exclude directory
                let pathComponents = fileURL.pathComponents
                if pathComponents.contains(where: { excludedDirs.contains($0) }) {
                    enumerator.skipDescendants()
                    continue
                }

                /// Check if file matches patterns
                let fileName = fileURL.lastPathComponent
                let matchesPattern = filePatterns.contains { pattern in
                    let regex = pattern.replacingOccurrences(of: "*", with: ".*")
                    return fileName.range(of: "^\(regex)$", options: .regularExpression) != nil
                }

                if matchesPattern {
                    /// Check if it's a file (not directory)
                    var isDir: ObjCBool = false
                    if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue {
                        fileURLs.append(fileURL)
                    }
                }
            }
        }

        scanDirectory(directoryURL)

        guard !fileURLs.isEmpty else {
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: "No files found matching patterns: \(filePatterns.joined(separator: ", "))", mimeType: "text/plain"),
                toolName: name
            )
        }

        logger.info("Found \(fileURLs.count) files to import")

        /// Import documents using DocumentImportSystem
        do {
            let importedDocs = try await documentImportSystem.importDocuments(
                from: fileURLs,
                conversationId: context.conversationId
            )

            var resultMessage = """
            CODEBASE INGESTION COMPLETE

            Directory: \(resolvedPath)
            Files processed: \(importedDocs.count)
            Total size: \(importedDocs.reduce(0) { $0 + $1.fileSize }) bytes
            
            Files imported to VectorRAG memory (searchable via memory_operations):
            """

            for doc in importedDocs.prefix(20) {
                resultMessage += "\n  - \(doc.filename) (\(doc.fileSize) bytes)"
            }

            if importedDocs.count > 20 {
                resultMessage += "\n  ... and \(importedDocs.count - 20) more"
            }

            /// Export training data if requested
            if exportTraining {
                guard let exportPath = exportPath else {
                    return MCPToolResult(
                        success: false,
                        output: MCPOutput(content: "export_training is true but export_path is not provided", mimeType: "text/plain"),
                        toolName: name
                    )
                }

                let resolvedExportPath = MCPAuthorizationGuard.resolvePath(exportPath, workingDirectory: context.workingDirectory)
                let exportURL = URL(fileURLWithPath: resolvedExportPath)

                /// Create TrainingDataExporter and export
                let exporter = TrainingDataExporter()
                let exportOptions = TrainingDataModels.DocumentExportOptions(
                    chunkingStrategy: .semantic,
                    maxChunkTokens: 512,
                    overlapTokens: 50,
                    stripPII: false,
                    selectedPIIEntities: [],
                    template: .llama3,
                    customTemplate: nil
                )

                /// Convert UserInterface.ImportedDocument to Training.ImportedDocument
                let trainingDocs = importedDocs.map { doc in
                    Training.ImportedDocument(
                        id: doc.id,
                        filename: doc.filename,
                        content: doc.content,
                        metadata: doc.metadata
                    )
                }

                let exportResult = try await exporter.exportDocuments(
                    documents: trainingDocs,
                    outputURL: exportURL,
                    options: exportOptions
                )

                resultMessage += """
                
                
                TRAINING DATA EXPORTED
                
                Output file: \(resolvedExportPath)
                Training examples: \(exportResult.statistics.totalExamples)
                Estimated tokens: \(exportResult.statistics.totalTokensEstimate)
                """
            }

            resultMessage += """
            
            
            Next steps:
            - Use memory_operations to search ingested code: {"operation": "search_memory", "query": "your search"}
            - Documents are stored with tags for filtering
            """

            return MCPToolResult(
                success: true,
                output: MCPOutput(content: resultMessage, mimeType: "text/plain"),
                toolName: name
            )

        } catch {
            logger.error("Codebase ingestion failed: \(error)")
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: "Codebase ingestion failed: \(error.localizedDescription)", mimeType: "text/plain"),
                toolName: name
            )
        }
    }
}
