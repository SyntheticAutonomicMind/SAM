// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import MCPFramework
import Logging

/// MCP tool for document creation capabilities Allows AI agents to autonomously create PDF, Markdown, and RTF documents.
public class DocumentCreateTool: MCPTool, @unchecked Sendable {
    public let name = "document_create"
    public let description = "Create formatted documents (PDF, DOCX, PPTX, Markdown, RTF, XLSX) from markdown content. CRITICAL: Content MUST use markdown syntax (# for headings, ** for bold, etc.) to apply formatting and styles. Plain text without markdown markers will render as plain paragraphs with no styling. Supports explicit formatting via parameters (fonts, colors, margins, page size). Use document_import first to extract formatting from existing documents."

    private let documentGenerator: DocumentGenerator
    private let logger = Logging.Logger(label: "com.sam.mcp.DocumentCreate")

    public var parameters: [String: MCPToolParameter] {
        [
            "content": MCPToolParameter(
                type: .string,
                description: "The main content for the document. CRITICAL: MUST use markdown formatting for proper styling:\n- Use # for Heading 1 (e.g., '# Main Title')\n- Use ## for Heading 2 (e.g., '## Section Name')\n- Use ### for Heading 3 (e.g., '### Subsection')\n- Use **text** for bold\n- Use *text* for italic\n- Use - or * for bullet lists\n- Plain text without # will appear as normal paragraphs with NO heading styles.\nExample: '# John Smith\\n\\nSoftware Engineer\\n\\n## Experience\\n\\nLed development of...'",
                required: true
            ),
            "filename": MCPToolParameter(
                type: .string,
                description: "Base filename without extension (e.g., 'Report_2025' will create 'Report_2025.pdf')",
                required: true
            ),
            "format": MCPToolParameter(
                type: .string,
                description: "Document format: 'pdf', 'docx', 'pptx', 'markdown', 'rtf', or 'xlsx'",
                required: false,
                enumValues: ["pdf", "docx", "pptx", "markdown", "rtf", "xlsx"]
            ),
            "output_path": MCPToolParameter(
                type: .string,
                description: "Optional custom output directory path (defaults to conversation working directory)",
                required: false
            ),
            "title": MCPToolParameter(
                type: .string,
                description: "Document title for metadata and header",
                required: false
            ),
            "author": MCPToolParameter(
                type: .string,
                description: "Author name for document metadata",
                required: false
            ),
            "description": MCPToolParameter(
                type: .string,
                description: "Brief description of document content",
                required: false
            ),
            "font_family": MCPToolParameter(
                type: .string,
                description: "Font family for body text (e.g., 'Helvetica', 'Times New Roman', 'Arial', 'Georgia'). Default: Helvetica",
                required: false
            ),
            "font_size": MCPToolParameter(
                type: .integer,
                description: "Base font size in points (8-72). Default: 12",
                required: false
            ),
            "heading1_size": MCPToolParameter(
                type: .integer,
                description: "Font size for level 1 headings in points. Default: 24",
                required: false
            ),
            "heading2_size": MCPToolParameter(
                type: .integer,
                description: "Font size for level 2 headings in points. Default: 20",
                required: false
            ),
            "heading3_size": MCPToolParameter(
                type: .integer,
                description: "Font size for level 3 headings in points. Default: 16",
                required: false
            ),
            "text_color": MCPToolParameter(
                type: .string,
                description: "Body text color as hex (e.g., '#000000' for black, '#333333' for dark gray). Default: #000000",
                required: false
            ),
            "heading_color": MCPToolParameter(
                type: .string,
                description: "Heading text color as hex (e.g., '#1a1a1a', '#0066cc'). Default: #000000",
                required: false
            ),
            "page_width": MCPToolParameter(
                type: .integer,
                description: "Page width in points (US Letter: 612, A4: 595). Default: 612",
                required: false
            ),
            "page_height": MCPToolParameter(
                type: .integer,
                description: "Page height in points (US Letter: 792, A4: 842). Default: 792",
                required: false
            ),
            "margin_top": MCPToolParameter(
                type: .integer,
                description: "Top margin in points (36pt = 0.5 inch). Default: 72",
                required: false
            ),
            "margin_bottom": MCPToolParameter(
                type: .integer,
                description: "Bottom margin in points. Default: 72",
                required: false
            ),
            "margin_left": MCPToolParameter(
                type: .integer,
                description: "Left margin in points. Default: 72",
                required: false
            ),
            "margin_right": MCPToolParameter(
                type: .integer,
                description: "Right margin in points. Default: 72",
                required: false
            ),
            "line_spacing": MCPToolParameter(
                type: .integer,
                description: "Line spacing multiplier (1.0 = single, 1.5 = one-and-half, 2.0 = double). Default: 1.15",
                required: false
            ),
            "template": MCPToolParameter(
                type: .string,
                description: "Template name for PPTX generation (e.g., 'Modern Blue'). SAM will search Office, user, and web templates.",
                required: false
            )
        ]
    }

    public init(documentGenerator: DocumentGenerator) {
        self.documentGenerator = documentGenerator
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        logger.debug("Executing document creation tool")
        logger.debug("DOCUMENT_CREATE: parameters=\(parameters.keys.sorted())")
        logger.info("DOCUMENT_CREATE: font_family=\(parameters["font_family"] as? String ?? "nil")")
        logger.info("DOCUMENT_CREATE: font_size=\(parameters["font_size"] as? Int ?? -1)")
        logger.info("DOCUMENT_CREATE: format=\(parameters["format"] as? String ?? "nil")")
        logger.info("DOCUMENT_CREATE: output_path=\(parameters["output_path"] as? String ?? "nil")")
        logger.info("DOCUMENT_CREATE: context.workingDirectory=\(context.workingDirectory ?? "nil")")

        /// Validate required parameters.
        guard let content = parameters["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return MCPToolResult(
                success: false,
                output: MCPOutput(
                    content: "Required parameter 'content' is missing or empty",
                    mimeType: "text/plain"
                ),
                toolName: name
            )
        }

        guard let filename = parameters["filename"] as? String,
              !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return MCPToolResult(
                success: false,
                output: MCPOutput(
                    content: "Required parameter 'filename' is missing or empty",
                    mimeType: "text/plain"
                ),
                toolName: name
            )
        }

        /// Parse optional parameters.
        let formatString = parameters["format"] as? String ?? "pdf"
        let outputPath = parameters["output_path"] as? String

        /// Parse format.
        guard let format = DocumentFormat(rawValue: formatString) else {
            return MCPToolResult(
                success: false,
                output: MCPOutput(
                    content: "Invalid format '\(formatString)'. Must be 'pdf', 'docx', 'pptx', 'markdown', 'rtf', or 'xlsx'",
                    mimeType: "text/plain"
                ),
                toolName: name
            )
        }

        /// Build metadata.
        var metadata: DocumentMetadata?
        if let title = parameters["title"] as? String {
            metadata = DocumentMetadata(
                title: title,
                author: parameters["author"] as? String,
                description: parameters["description"] as? String,
                createdDate: Date(),
                tags: []
            )
        }

        /// Build formatting metadata from parameters.
        /// Build formatting metadata from parameters.
        let formattingMetadata = buildFormattingMetadata(from: parameters, format: format)

        logger.debug("Document create request: filename='\(filename)', format='\(formatString)', contentLength=\(content.count)")
        if let formatting = formattingMetadata {
            logger.debug("Custom formatting specified: font=\(formatting.defaultFont?.familyName ?? "default"), size=\(formatting.defaultFontSize ?? 12)")
        }

        /// Pass working directory from context to DocumentGenerator This ensures documents are created in the conversation working directory by default.
        logger.debug("Using working directory: \(context.workingDirectory ?? "nil (will use fallback)")")

        /// AUTHORIZATION CHECK: If output_path is specified and differs from working directory, verify authorization
        if let customOutputPath = outputPath, let workingDir = context.workingDirectory {
            /// Resolve the output path to absolute path
            let outputURL: URL
            if customOutputPath.hasPrefix("/") || customOutputPath.hasPrefix("~") {
                outputURL = URL(fileURLWithPath: (customOutputPath as NSString).expandingTildeInPath)
            } else {
                outputURL = URL(fileURLWithPath: workingDir).appendingPathComponent(customOutputPath)
            }

            /// Check if the output path is within workspace
            let authResult = MCPAuthorizationGuard.checkPathAuthorization(
                path: outputURL.path,
                workingDirectory: workingDir,
                conversationId: context.conversationId,
                operation: "document_create",
                isUserInitiated: context.isUserInitiated
            )

            switch authResult {
            case .allowed(let reason):
                logger.debug("Document creation authorized: \(reason)")

            case .denied(let reason):
                return MCPToolResult(
                    success: false,
                    output: MCPOutput(content: "Document creation denied: \(reason)", mimeType: "text/plain"),
                    toolName: name
                )

            case .requiresAuthorization(let reason):
                let authError = MCPAuthorizationGuard.authorizationError(
                    operation: "document_create",
                    reason: reason,
                    suggestedPrompt: "May I create a document at \(outputURL.path)?"
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
                    output: MCPOutput(content: "Authorization required for path: \(outputURL.path)", mimeType: "text/plain"),
                    toolName: name
                )
            }
        }

        /// Handle PPTX generation separately (uses Python script)
        if format == .pptx {
            do {
                let pptxGenerator = PPTXGenerator()

                // Discover template if specified
                var template: DocumentTemplate?
                if let templateName = parameters["template"] as? String {
                    let discovery = TemplateDiscoveryService()
                    let templates = discovery.discoverTemplates(format: "pptx")
                    template = templates.first { $0.name.lowercased().contains(templateName.lowercased()) }

                    if template != nil {
                        logger.debug("Using template: \(template!.name)")
                    } else {
                        logger.warning("Template '\(templateName)' not found, using default")
                    }
                }

                // Determine output path
                let workingDir = context.workingDirectory ?? NSHomeDirectory()
                let outputDir = outputPath ?? workingDir
                let outputURL = URL(fileURLWithPath: outputDir)
                    .appendingPathComponent(filename)
                    .appendingPathExtension("pptx")

                // Generate PPTX
                logger.info("Generating PPTX: \(outputURL.lastPathComponent)")
                let fileURL = try pptxGenerator.generate(
                    markdown: content,
                    outputPath: outputURL,
                    template: template
                )

                let successMessage = """
                SUCCESS: PowerPoint presentation created successfully

                Format: PPTX
                Location: \(fileURL.path)
                Filename: \(fileURL.lastPathComponent)
                Template: \(template?.name ?? "Default")

                The presentation has been saved and is ready to use.
                """

                return MCPToolResult(
                    success: true,
                    output: MCPOutput(
                        content: successMessage,
                        mimeType: "text/plain"
                    ),
                    toolName: name
                )
            } catch {
                logger.error("PPTX generation failed: \(error.localizedDescription)")
                return MCPToolResult(
                    success: false,
                    output: MCPOutput(
                        content: "Failed to generate PowerPoint: \(error.localizedDescription)",
                        mimeType: "text/plain"
                    ),
                    toolName: name
                )
            }
        }

        /// Generate document (PDF, DOCX, etc).
        logger.info("DOCGEN_START: Calling DocumentGenerator.generateDocument()")
        do {
            let fileURL = try await documentGenerator.generateDocument(
                content: content,
                filename: filename,
                format: format,
                outputPath: outputPath,
                metadata: metadata,
                formattingMetadata: formattingMetadata,
                workingDirectory: context.workingDirectory
            )

            /// CRITICAL: Put filename FIRST and prominently so LLM knows what was created
            /// and doesn't try to create the same document again
            let filename = fileURL.lastPathComponent
            let successMessage = """
            DOCUMENT CREATED: \(filename)

            Format: \(format.rawValue.uppercased())
            Path: \(fileURL.path)
            Size: \(content.count) characters

            This document now exists - DO NOT create it again.
            """

            return MCPToolResult(
                success: true,
                output: MCPOutput(
                    content: successMessage,
                    mimeType: "text/plain",
                    additionalData: [
                        "file_path": fileURL.path,
                        "filename": filename,
                        "format": format.rawValue,
                        "content_length": content.count
                    ]
                ),
                toolName: name
            )

        } catch {
            logger.error("DOCGEN_ERROR: Document creation failed: \(error)")
            logger.error("DOCGEN_ERROR_DETAIL: \(String(reflecting: error))")

            let errorMessage = """
            ERROR: Document creation failed

            Error: \(error.localizedDescription)

            Please check:
            - Output path is valid and writable
            - Filename doesn't contain invalid characters
            - Sufficient disk space available
            """

            return MCPToolResult(
                success: false,
                output: MCPOutput(
                    content: errorMessage,
                    mimeType: "text/plain"
                ),
                toolName: name
            )
        }
    }

    // MARK: - Helper Methods

    /// Parse formatting parameters and build FormattingMetadata.
    private func buildFormattingMetadata(from parameters: [String: Any], format: DocumentFormat) -> FormattingMetadata? {
        /// Only apply custom formatting for formats that support it (PDF, DOCX).
        guard format == .pdf || format == .docx else {
            return nil
        }

        /// Check if any formatting parameters were provided.
        let hasFormattingParams = parameters["font_family"] != nil ||
                                  parameters["font_size"] != nil ||
                                  parameters["heading1_size"] != nil ||
                                  parameters["text_color"] != nil ||
                                  parameters["heading_color"] != nil ||
                                  parameters["page_width"] != nil ||
                                  parameters["margin_top"] != nil ||
                                  parameters["line_spacing"] != nil

        /// If no formatting parameters provided, return nil to use defaults.
        guard hasFormattingParams else {
            return nil
        }

        /// Parse font parameters.
        let fontFamily = parameters["font_family"] as? String ?? "Helvetica"
        let fontSize = (parameters["font_size"] as? Double) ?? 12.0

        /// Parse heading sizes.
        let heading1Size = (parameters["heading1_size"] as? Double) ?? 24.0
        let heading2Size = (parameters["heading2_size"] as? Double) ?? 20.0
        let heading3Size = (parameters["heading3_size"] as? Double) ?? 16.0

        /// Parse colors (hex strings like "#000000").
        let textColor = parseColor(parameters["text_color"] as? String ?? "#000000")
        let headingColor = parseColor(parameters["heading_color"] as? String ?? "#000000")

        /// Parse page dimensions.
        let pageWidth = (parameters["page_width"] as? Double) ?? 612.0
        let pageHeight = (parameters["page_height"] as? Double) ?? 792.0

        /// Parse margins.
        let marginTop = (parameters["margin_top"] as? Double) ?? 72.0
        let marginBottom = (parameters["margin_bottom"] as? Double) ?? 72.0
        let marginLeft = (parameters["margin_left"] as? Double) ?? 72.0
        let marginRight = (parameters["margin_right"] as? Double) ?? 72.0

        /// Parse line spacing.
        let lineSpacing = (parameters["line_spacing"] as? Double) ?? 1.15

        /// Create font metadata.
        let defaultFont = FontMetadata(
            familyName: fontFamily,
            weight: "regular",
            isItalic: false,
            isMonospaced: false
        )

        /// Create heading styles.
        var headingStyles: [Int: HeadingStyleMetadata] = [:]
        headingStyles[1] = HeadingStyleMetadata(
            level: 1,
            font: FontMetadata(familyName: fontFamily, weight: "bold"),
            fontSize: heading1Size,
            textColor: headingColor,
            spacingBefore: 12,
            spacingAfter: 6
        )
        headingStyles[2] = HeadingStyleMetadata(
            level: 2,
            font: FontMetadata(familyName: fontFamily, weight: "bold"),
            fontSize: heading2Size,
            textColor: headingColor,
            spacingBefore: 10,
            spacingAfter: 5
        )
        headingStyles[3] = HeadingStyleMetadata(
            level: 3,
            font: FontMetadata(familyName: fontFamily, weight: "bold"),
            fontSize: heading3Size,
            textColor: headingColor,
            spacingBefore: 8,
            spacingAfter: 4
        )

        /// Create page size metadata.
        let pageSize = PageSizeMetadata(
            width: pageWidth,
            height: pageHeight
        )

        /// Create margins metadata.
        let margins = MarginsMetadata(
            top: marginTop,
            bottom: marginBottom,
            left: marginLeft,
            right: marginRight
        )

        /// Build complete FormattingMetadata.
        return FormattingMetadata(
            defaultFont: defaultFont,
            defaultFontSize: fontSize,
            defaultTextColor: textColor,
            pageSize: pageSize,
            margins: margins,
            headingStyles: headingStyles,
            sourceFormat: format
        )
    }

    /// Merge two FormattingMetadata objects, with overrides taking precedence
    /// - Parameters:
    /// Parse hex color string to ColorMetadata.
    private func parseColor(_ hexString: String) -> ColorMetadata {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }

        /// Parse RGB components.
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)

        let red = Double((rgb >> 16) & 0xFF) / 255.0
        let green = Double((rgb >> 8) & 0xFF) / 255.0
        let blue = Double(rgb & 0xFF) / 255.0

        return ColorMetadata(red: red, green: green, blue: blue, alpha: 1.0)
    }
}
