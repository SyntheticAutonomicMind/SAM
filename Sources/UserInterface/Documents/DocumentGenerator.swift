// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import PDFKit
import UniformTypeIdentifiers
import ZIPFoundation
import Logging

/// Document generation service for creating PDF, Markdown, and RTF documents Supports formatted output with metadata, code highlighting, and flexible content.
public class DocumentGenerator: @unchecked Sendable {
    private let logger = Logging.Logger(label: "com.sam.documents.DocumentGenerator")

    public init() {}

    // MARK: - Public API

    /// Generate a document in the specified format - Parameters: - content: The main content for the document - filename: Base filename (without extension) - format: Document format (pdf, markdown, rtf) - outputPath: Optional custom output path (defaults to conversation working directory) - metadata: Optional metadata (title, author, date, etc.) - workingDirectory: Conversation working directory from execution context - Returns: URL of the created document.
    public func generateDocument(
        content: String,
        filename: String,
        format: DocumentFormat,
        outputPath: String? = nil,
        metadata: DocumentMetadata? = nil,
        formattingMetadata: FormattingMetadata? = nil,
        workingDirectory: String? = nil
    ) async throws -> URL {
        logger.info("Generating document: filename='\(filename)', format='\(format.rawValue)'")

        /// Determine output directory.
        let outputDirectory = try resolveOutputDirectory(outputPath, workingDirectory: workingDirectory)

        /// Sanitize filename.
        let sanitizedFilename = sanitizeFilename(filename)

        /// Generate document based on format.
        let fileURL: URL
        switch format {
        case .pdf:
            fileURL = try await generatePDF(
                content: content,
                filename: sanitizedFilename,
                outputDirectory: outputDirectory,
                metadata: metadata,
                formattingMetadata: formattingMetadata
            )

        case .markdown:
            fileURL = try generateMarkdown(
                content: content,
                filename: sanitizedFilename,
                outputDirectory: outputDirectory,
                metadata: metadata
            )

        case .rtf:
            fileURL = try generateRTF(
                content: content,
                filename: sanitizedFilename,
                outputDirectory: outputDirectory,
                metadata: metadata
            )

        case .docx:
            fileURL = try generateWordDocument(
                content: content,
                filename: sanitizedFilename,
                outputDirectory: outputDirectory,
                metadata: metadata,
                formattingMetadata: formattingMetadata
            )

        case .xlsx:
            fileURL = try generateExcelDocument(
                content: content,
                filename: sanitizedFilename,
                outputDirectory: outputDirectory,
                metadata: metadata
            )

        case .txt:
            /// Plain text format - just write content as-is.
            fileURL = try generatePlainText(
                content: content,
                filename: sanitizedFilename,
                outputDirectory: outputDirectory
            )

        case .html:
            /// HTML format - not yet implemented.
            throw DocumentGeneratorError.invalidFormat("HTML format is not yet supported")

        case .pptx:
            /// PPTX format - handled by PPTXGenerator in DocumentCreateTool.
            throw DocumentGeneratorError.invalidFormat("PPTX format should be handled by PPTXGenerator")

        case .unknown:
            throw DocumentGeneratorError.invalidFormat("Unknown document format")
        }

        logger.debug("Document generated successfully: \(fileURL.path)")
        return fileURL
    }

    // MARK: - PDF Generation

    private func generatePDF(
        content: String,
        filename: String,
        outputDirectory: URL,
        metadata: DocumentMetadata?,
        formattingMetadata: FormattingMetadata?
    ) async throws -> URL {
        /// Use AST-based renderer (inspired by md2pdf architecture).
        let renderer = MarkdownASTRenderer()
        guard let pdfData = renderer.renderToPDF(
            markdown: content,
            metadata: metadata,
            formattingMetadata: formattingMetadata
        ) else {
            throw DocumentGeneratorError.writeFailed("Failed to render markdown to PDF")
        }

        /// Create PDFDocument from data.
        guard let pdfDocument = PDFDocument(data: pdfData) else {
            throw DocumentGeneratorError.writeFailed("Failed to create PDF document from data")
        }

        /// Add metadata.
        if let metadata = metadata {
            setPDFMetadata(pdfDocument, metadata: metadata)
        }

        /// Write to file.
        let fileURL = outputDirectory.appendingPathComponent("\(filename).pdf")
        guard pdfDocument.write(to: fileURL) else {
            throw DocumentGeneratorError.writeFailed("Failed to write PDF to \(fileURL.path)")
        }

        return fileURL
    }

    private func formatContentForPDF(content: String, metadata: DocumentMetadata?) -> NSAttributedString {
        let attributedString = NSMutableAttributedString()

        /// Add title page if metadata present.
        if let metadata = metadata {
            let titleFont = NSFont.boldSystemFont(ofSize: 24)
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: titleFont,
                .foregroundColor: NSColor.black
            ]

            let titleString = NSAttributedString(
                string: "\(metadata.title)\n\n",
                attributes: titleAttributes
            )
            attributedString.append(titleString)

            /// Add metadata info.
            let metadataFont = NSFont.systemFont(ofSize: 12)
            let metadataAttributes: [NSAttributedString.Key: Any] = [
                .font: metadataFont,
                .foregroundColor: NSColor.darkGray
            ]

            var metadataText = ""
            if let author = metadata.author {
                metadataText += "Author: \(author)\n"
            }
            metadataText += "Created: \(metadata.createdDate.formatted(date: .long, time: .shortened))\n"
            if let description = metadata.description {
                metadataText += "\(description)\n"
            }
            metadataText += "\n\n"

            let metadataString = NSAttributedString(
                string: metadataText,
                attributes: metadataAttributes
            )
            attributedString.append(metadataString)
        }

        /// Parse and format markdown content.
        let markdownString = parseMarkdownToPDFAttributedString(content)
        attributedString.append(markdownString)

        return attributedString
    }

    /// Parse markdown content into NSAttributedString for PDF rendering Supports: # headers, ## subheaders, **bold**, *italic*, and code blocks.
    private func parseMarkdownToPDFAttributedString(_ markdown: String) -> NSAttributedString {
        let attributedString = NSMutableAttributedString()

        /// Default styles.
        let bodyFont = NSFont.systemFont(ofSize: 12)
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor.black
        ]

        let headerFont = NSFont.boldSystemFont(ofSize: 18)
        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: headerFont,
            .foregroundColor: NSColor.black
        ]

        let subheaderFont = NSFont.boldSystemFont(ofSize: 14)
        let subheaderAttributes: [NSAttributedString.Key: Any] = [
            .font: subheaderFont,
            .foregroundColor: NSColor.black
        ]

        let boldFont = NSFont.boldSystemFont(ofSize: 12)
        let italicFont = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
        let codeFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        /// Process line by line.
        let lines = markdown.components(separatedBy: .newlines)

        for line in lines {
            var processedLine = line
            var lineAttributes = bodyAttributes

            /// Handle headers.
            if processedLine.hasPrefix("# ") {
                processedLine = String(processedLine.dropFirst(2))
                lineAttributes = headerAttributes
                let headerString = NSAttributedString(
                    string: processedLine + "\n\n",
                    attributes: lineAttributes
                )
                attributedString.append(headerString)
                continue
            } else if processedLine.hasPrefix("## ") {
                processedLine = String(processedLine.dropFirst(3))
                lineAttributes = subheaderAttributes
                let subheaderString = NSAttributedString(
                    string: processedLine + "\n\n",
                    attributes: lineAttributes
                )
                attributedString.append(subheaderString)
                continue
            } else if processedLine.hasPrefix("### ") {
                processedLine = String(processedLine.dropFirst(4))
                let subsubheaderFont = NSFont.boldSystemFont(ofSize: 12)
                let subsubheaderAttributes: [NSAttributedString.Key: Any] = [
                    .font: subsubheaderFont,
                    .foregroundColor: NSColor.black
                ]
                let subsubheaderString = NSAttributedString(
                    string: processedLine + "\n\n",
                    attributes: subsubheaderAttributes
                )
                attributedString.append(subsubheaderString)
                continue
            }

            /// Handle inline formatting (bold, italic, code).
            let lineString = parseInlineMarkdown(processedLine, bodyFont: bodyFont, boldFont: boldFont, italicFont: italicFont, codeFont: codeFont)
            attributedString.append(lineString)
            attributedString.append(NSAttributedString(string: "\n", attributes: bodyAttributes))
        }

        return attributedString
    }

    /// Parse inline markdown formatting: **bold**, *italic*, `code`.
    private func parseInlineMarkdown(_ text: String, bodyFont: NSFont, boldFont: NSFont, italicFont: NSFont, codeFont: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()

        var currentText = text
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor.black
        ]

        /// Simple regex-free parsing for common patterns.
        while !currentText.isEmpty {
            /// Check for **bold**.
            if let boldRange = currentText.range(of: "**") {
                /// Add text before bold.
                let beforeBold = String(currentText[..<boldRange.lowerBound])
                result.append(NSAttributedString(string: beforeBold, attributes: bodyAttributes))

                /// Find closing **.
                let afterFirstBold = currentText[boldRange.upperBound...]
                if let closeBoldRange = afterFirstBold.range(of: "**") {
                    let boldText = String(afterFirstBold[..<closeBoldRange.lowerBound])
                    let boldAttributes: [NSAttributedString.Key: Any] = [
                        .font: boldFont,
                        .foregroundColor: NSColor.black
                    ]
                    result.append(NSAttributedString(string: boldText, attributes: boldAttributes))
                    currentText = String(afterFirstBold[closeBoldRange.upperBound...])
                    continue
                } else {
                    /// No closing **, treat as literal.
                    result.append(NSAttributedString(string: "**", attributes: bodyAttributes))
                    currentText = String(afterFirstBold)
                    continue
                }
            }

            /// Check for *italic* (but not part of **).
            else if let italicRange = currentText.range(of: "*"),
                    !currentText[italicRange.lowerBound...].hasPrefix("**") {
                /// Add text before italic.
                let beforeItalic = String(currentText[..<italicRange.lowerBound])
                result.append(NSAttributedString(string: beforeItalic, attributes: bodyAttributes))

                /// Find closing *.
                let afterFirstItalic = currentText[italicRange.upperBound...]
                if let closeItalicRange = afterFirstItalic.range(of: "*") {
                    /// Check if this closing * is part of ** (check character before it).
                    let beforeClosing = afterFirstItalic[..<closeItalicRange.lowerBound]
                    let isPartOfBold = beforeClosing.hasSuffix("*")

                    if !isPartOfBold {
                        let italicText = String(afterFirstItalic[..<closeItalicRange.lowerBound])
                        let italicAttributes: [NSAttributedString.Key: Any] = [
                            .font: italicFont,
                            .foregroundColor: NSColor.black
                        ]
                        result.append(NSAttributedString(string: italicText, attributes: italicAttributes))
                        currentText = String(afterFirstItalic[closeItalicRange.upperBound...])
                        continue
                    } else {
                        /// Part of **, treat as literal.
                        result.append(NSAttributedString(string: "*", attributes: bodyAttributes))
                        currentText = String(afterFirstItalic)
                        continue
                    }
                } else {
                    /// No closing *, treat as literal.
                    result.append(NSAttributedString(string: "*", attributes: bodyAttributes))
                    currentText = String(afterFirstItalic)
                    continue
                }
            }

            /// Check for `code`.
            else if let codeRange = currentText.range(of: "`") {
                /// Add text before code.
                let beforeCode = String(currentText[..<codeRange.lowerBound])
                result.append(NSAttributedString(string: beforeCode, attributes: bodyAttributes))

                /// Find closing `.
                let afterFirstCode = currentText[codeRange.upperBound...]
                if let closeCodeRange = afterFirstCode.range(of: "`") {
                    let codeText = String(afterFirstCode[..<closeCodeRange.lowerBound])
                    let codeAttributes: [NSAttributedString.Key: Any] = [
                        .font: codeFont,
                        .foregroundColor: NSColor.darkGray,
                        .backgroundColor: NSColor.lightGray.withAlphaComponent(0.2)
                    ]
                    result.append(NSAttributedString(string: codeText, attributes: codeAttributes))
                    currentText = String(afterFirstCode[closeCodeRange.upperBound...])
                    continue
                } else {
                    /// No closing `, treat as literal.
                    result.append(NSAttributedString(string: "`", attributes: bodyAttributes))
                    currentText = String(afterFirstCode)
                    continue
                }
            }

            /// No special formatting found, append rest of text.
            else {
                result.append(NSAttributedString(string: currentText, attributes: bodyAttributes))
                break
            }
        }

        return result
    }

    private func setPDFMetadata(_ document: PDFDocument, metadata: DocumentMetadata) {
        var attributes: [PDFDocumentAttribute: Any] = [:]

        attributes[.titleAttribute] = metadata.title
        if let author = metadata.author {
            attributes[.authorAttribute] = author
        }
        attributes[.creationDateAttribute] = metadata.createdDate
        if let description = metadata.description {
            attributes[.subjectAttribute] = description
        }

        document.documentAttributes = attributes
    }

    // MARK: - down Generation

    private func generateMarkdown(
        content: String,
        filename: String,
        outputDirectory: URL,
        metadata: DocumentMetadata?
    ) throws -> URL {
        var markdownContent = ""

        /// Add metadata as frontmatter.
        if let metadata = metadata {
            markdownContent += "---\n"
            markdownContent += "title: \(metadata.title)\n"
            if let author = metadata.author {
                markdownContent += "author: \(author)\n"
            }
            markdownContent += "date: \(metadata.createdDate.formatted(date: .long, time: .shortened))\n"
            if let description = metadata.description {
                markdownContent += "description: \(description)\n"
            }
            markdownContent += "---\n\n"

            markdownContent += "# \(metadata.title)\n\n"
        }

        /// Add main content.
        markdownContent += content

        /// Write to file.
        let fileURL = outputDirectory.appendingPathComponent("\(filename).md")
        try markdownContent.write(to: fileURL, atomically: true, encoding: .utf8)

        return fileURL
    }

    // MARK: - RTF Generation

    private func generateRTF(
        content: String,
        filename: String,
        outputDirectory: URL,
        metadata: DocumentMetadata?
    ) throws -> URL {
        let attributedString = NSMutableAttributedString()

        /// Add title and metadata.
        if let metadata = metadata {
            let titleFont = NSFont.boldSystemFont(ofSize: 18)
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: titleFont
            ]

            let titleString = NSAttributedString(
                string: "\(metadata.title)\n\n",
                attributes: titleAttributes
            )
            attributedString.append(titleString)

            /// Add metadata.
            let metadataFont = NSFont.systemFont(ofSize: 11)
            let metadataAttributes: [NSAttributedString.Key: Any] = [
                .font: metadataFont,
                .foregroundColor: NSColor.darkGray
            ]

            var metadataText = ""
            if let author = metadata.author {
                metadataText += "Author: \(author)\n"
            }
            metadataText += "Created: \(metadata.createdDate.formatted(date: .long, time: .shortened))\n"
            if let description = metadata.description {
                metadataText += "\(description)\n"
            }
            metadataText += "\n"

            let metadataString = NSAttributedString(
                string: metadataText,
                attributes: metadataAttributes
            )
            attributedString.append(metadataString)
        }

        /// Add content.
        let bodyFont = NSFont.systemFont(ofSize: 12)
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont
        ]

        let bodyString = NSAttributedString(
            string: content,
            attributes: bodyAttributes
        )
        attributedString.append(bodyString)

        /// Convert to RTF.
        guard let rtfData = attributedString.rtf(
            from: NSRange(location: 0, length: attributedString.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) else {
            throw DocumentGeneratorError.conversionFailed("Failed to convert content to RTF")
        }

        /// Write to file.
        let fileURL = outputDirectory.appendingPathComponent("\(filename).rtf")
        try rtfData.write(to: fileURL)

        return fileURL
    }

    // MARK: - Word Document Generation (.docx)

    private func generateWordDocument(
        content: String,
        filename: String,
        outputDirectory: URL,
        metadata: DocumentMetadata?,
        formattingMetadata: FormattingMetadata?
    ) throws -> URL {
        logger.info("Generating Word document: \(filename).docx")
        logger.debug("DOCX_GEN: Step 1 - Starting generation, outputDir=\(outputDirectory.path)")

        let fileURL = outputDirectory.appendingPathComponent("\(filename).docx")
        logger.debug("DOCX_GEN: Step 2 - Target file: \(fileURL.path)")

        /// Create temporary directory for DOCX structure.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        logger.debug("DOCX_GEN: Step 3 - Creating temp dir: \(tempDir.path)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        logger.debug("DOCX_GEN: Step 4 - Temp dir created successfully")

        defer {
            logger.info("DOCX_GEN: Step DEFER - Cleaning up temp dir")
            try? FileManager.default.removeItem(at: tempDir)
        }

        /// Build DOCX structure.
        logger.debug("DOCX_GEN: Step 5 - Building DOCX structure")
        try createWordDocumentStructure(
            at: tempDir,
            content: content,
            metadata: metadata,
            formattingMetadata: formattingMetadata
        )
        logger.debug("DOCX_GEN: Step 6 - DOCX structure created successfully")

        /// Create ZIP archive.
        logger.debug("DOCX_GEN: Step 7 - Creating ZIP archive")
        try createZIPArchive(from: tempDir, to: fileURL)
        logger.debug("DOCX_GEN: Step 8 - ZIP archive created successfully")

        logger.debug("DOCX_GEN: Step 9 - Final check - file exists: \(FileManager.default.fileExists(atPath: fileURL.path))")
        logger.debug("Word document created: \(fileURL.path)")
        return fileURL
    }
    private func createWordDocumentStructure(
        at baseURL: URL,
        content: String,
        metadata: DocumentMetadata?,
        formattingMetadata: FormattingMetadata?
    ) throws {
        logger.info("DOCX_STRUCTURE: formattingMetadata provided: \(formattingMetadata != nil)")
        if let formatting = formattingMetadata {
            logger.info("DOCX_STRUCTURE: font=\(formatting.defaultFont?.familyName ?? "nil"), size=\(formatting.defaultFontSize ?? 0)")
        }

        /// Create directory structure.
        try FileManager.default.createDirectory(at: baseURL.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: baseURL.appendingPathComponent("word/_rels"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: baseURL.appendingPathComponent("word/media"), withIntermediateDirectories: true)

        /// Convert markdown content to get paragraphs and images
        let converter = MarkdownToDOCXConverter()
        let conversionResult = converter.convertWithImages(markdown: content)
        let embeddedImages = conversionResult.images

        logger.info("DOCX_STRUCTURE: Content converted with \(embeddedImages.count) embedded images")

        /// [Content_Types].xml - include image types if we have images
        var contentTypesEntries = """
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
            <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        """

        // Add image content types
        var hasAddedPng = false
        var hasAddedJpeg = false
        for image in embeddedImages {
            if image.contentType == "image/png" && !hasAddedPng {
                contentTypesEntries += "\n    <Default Extension=\"png\" ContentType=\"image/png\"/>"
                hasAddedPng = true
            } else if image.contentType == "image/jpeg" && !hasAddedJpeg {
                contentTypesEntries += "\n    <Default Extension=\"jpeg\" ContentType=\"image/jpeg\"/>"
                hasAddedJpeg = true
            }
        }

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        \(contentTypesEntries)
        </Types>
        """
        try contentTypes.write(to: baseURL.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)

        /// _rels/.rels.
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
        try rels.write(to: baseURL.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)

        /// word/_rels/document.xml.rels - include styles and image relationships
        var docRelsEntries = """
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        """

        // Add image relationships
        for image in embeddedImages {
            docRelsEntries += """

            <Relationship Id="\(image.relationshipId)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/\(image.filename)"/>
            """
        }

        let docRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \(docRelsEntries)
        </Relationships>
        """
        try docRels.write(to: baseURL.appendingPathComponent("word/_rels/document.xml.rels"), atomically: true, encoding: .utf8)

        /// Write image files to word/media/
        for image in embeddedImages {
            let imageURL = baseURL.appendingPathComponent("word/media/\(image.filename)")
            try image.imageData.write(to: imageURL)
            logger.debug("DOCX_STRUCTURE: Wrote image \(image.filename)")
        }

        /// word/document.xml (main content).
        var paragraphs = ""

        /// Add title if present.
        if let title = metadata?.title {
            paragraphs += """
                <w:p>
                    <w:pPr>
                        <w:pStyle w:val="Title"/>
                    </w:pPr>
                    <w:r>
                        <w:rPr>
                            <w:b/>
                            <w:sz w:val="32"/>
                        </w:rPr>
                        <w:t>\(xmlEscape(title))</w:t>
                    </w:r>
                </w:p>
            """
        }

        /// Add metadata if present.
        if let metadata = metadata {
            var metaLines: [String] = []
            if let author = metadata.author {
                metaLines.append("Author: \(author)")
            }
            metaLines.append("Created: \(metadata.createdDate.formatted(date: .long, time: .shortened))")
            if let description = metadata.description {
                metaLines.append(description)
            }

            for line in metaLines {
                paragraphs += """
                    <w:p>
                        <w:r>
                            <w:rPr>
                                <w:sz w:val="18"/>
                                <w:color w:val="666666"/>
                            </w:rPr>
                            <w:t>\(xmlEscape(line))</w:t>
                        </w:r>
                    </w:p>
                """
            }

            /// Empty paragraph separator.
            paragraphs += "<w:p/>"
        }

        /// Add converted markdown content
        paragraphs += conversionResult.paragraphsXML

        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
                    xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
                    xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                    xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
            <w:body>
        \(paragraphs)
            </w:body>
        </w:document>
        """
        try documentXML.write(to: baseURL.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)

        /// Generate styles.xml using formattingMetadata if provided, otherwise use defaults.
        let stylesXML = generateStylesXML(formattingMetadata: formattingMetadata)
        try stylesXML.write(to: baseURL.appendingPathComponent("word/styles.xml"), atomically: true, encoding: .utf8)
    }

    /// Generate styles.xml with dynamic formatting based on FormattingMetadata - Parameter formattingMetadata: Optional formatting configuration - Returns: XML string for styles.xml.
    private func generateStylesXML(formattingMetadata: FormattingMetadata?) -> String {
        /// Extract formatting values or use defaults.
        let defaultFont = formattingMetadata?.defaultFont?.familyName ?? "Calibri"
        let defaultFontSize = Int((formattingMetadata?.defaultFontSize ?? 11.0) * 2) // Word uses half-points
        let textColor = formattingMetadata?.defaultTextColor?.toHex() ?? "000000"

        /// Extract heading styles or use defaults.
        let h1Size = Int((formattingMetadata?.headingStyles[1]?.fontSize ?? 20.0) * 2)
        let h1Color = formattingMetadata?.headingStyles[1]?.textColor.toHex() ?? "2E74B5"

        let h2Size = Int((formattingMetadata?.headingStyles[2]?.fontSize ?? 16.0) * 2)
        let h2Color = formattingMetadata?.headingStyles[2]?.textColor.toHex() ?? "2E74B5"

        let h3Size = Int((formattingMetadata?.headingStyles[3]?.fontSize ?? 14.0) * 2)
        let h3Color = formattingMetadata?.headingStyles[3]?.textColor.toHex() ?? "1F4D78"

        logger.info("STYLES_XML: Using font=\(defaultFont), size=\(defaultFontSize/2)pt, color=#\(textColor)")
        logger.info("STYLES_XML: H1=\(h1Size/2)pt #\(h1Color), H2=\(h2Size/2)pt #\(h2Color), H3=\(h3Size/2)pt #\(h3Color)")

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <!-- Default paragraph style -->
            <w:docDefaults>
                <w:rPrDefault>
                    <w:rPr>
                        <w:rFonts w:ascii="\(defaultFont)" w:hAnsi="\(defaultFont)"/>
                        <w:sz w:val="\(defaultFontSize)"/>
                        <w:color w:val="\(textColor)"/>
                    </w:rPr>
                </w:rPrDefault>
                <w:pPrDefault>
                    <w:pPr>
                        <w:spacing w:after="200" w:line="276" w:lineRule="auto"/>
                    </w:pPr>
                </w:pPrDefault>
            </w:docDefaults>

            <!-- Title style -->
            <w:style w:type="paragraph" w:styleId="Title">
                <w:name w:val="Title"/>
                <w:basedOn w:val="Normal"/>
                <w:pPr>
                    <w:spacing w:before="240" w:after="60"/>
                    <w:jc w:val="center"/>
                </w:pPr>
                <w:rPr>
                    <w:b/>
                    <w:sz w:val="\(h1Size + 16)"/>
                    <w:szCs w:val="\(h1Size + 16)"/>
                </w:rPr>
            </w:style>

            <!-- Heading 1 style -->
            <w:style w:type="paragraph" w:styleId="Heading1">
                <w:name w:val="Heading 1"/>
                <w:basedOn w:val="Normal"/>
                <w:pPr>
                    <w:spacing w:before="480" w:after="240"/>
                    <w:keepNext/>
                </w:pPr>
                <w:rPr>
                    <w:b/>
                    <w:sz w:val="\(h1Size)"/>
                    <w:szCs w:val="\(h1Size)"/>
                    <w:color w:val="\(h1Color)"/>
                </w:rPr>
            </w:style>

            <!-- Heading 2 style -->
            <w:style w:type="paragraph" w:styleId="Heading2">
                <w:name w:val="Heading 2"/>
                <w:basedOn w:val="Normal"/>
                <w:pPr>
                    <w:spacing w:before="240" w:after="120"/>
                    <w:keepNext/>
                </w:pPr>
                <w:rPr>
                    <w:b/>
                    <w:sz w:val="\(h2Size)"/>
                    <w:szCs w:val="\(h2Size)"/>
                    <w:color w:val="\(h2Color)"/>
                </w:rPr>
            </w:style>

            <!-- Heading 3 style -->
            <w:style w:type="paragraph" w:styleId="Heading3">
                <w:name w:val="Heading 3"/>
                <w:basedOn w:val="Normal"/>
                <w:pPr>
                    <w:spacing w:before="240" w:after="120"/>
                </w:pPr>
                <w:rPr>
                    <w:b/>
                    <w:sz w:val="\(h3Size)"/>
                    <w:szCs w:val="\(h3Size)"/>
                    <w:color w:val="\(h3Color)"/>
                </w:rPr>
            </w:style>

            <!-- List Paragraph style -->
            <w:style w:type="paragraph" w:styleId="ListParagraph">
                <w:name w:val="List Paragraph"/>
                <w:basedOn w:val="Normal"/>
                <w:pPr>
                    <w:ind w:left="720"/>
                </w:pPr>
            </w:style>

            <!-- Code style -->
            <w:style w:type="character" w:styleId="Code">
                <w:name w:val="Code"/>
                <w:rPr>
                    <w:rFonts w:ascii="Courier New" w:hAnsi="Courier New"/>
                    <w:sz w:val="20"/>
                    <w:color w:val="C7254E"/>
                    <w:shd w:val="clear" w:color="auto" w:fill="F9F2F4"/>
                </w:rPr>
            </w:style>
        </w:styles>
        """
    }

    // MARK: - Excel Document Generation (.xlsx)

    private func generateExcelDocument(
        content: String,
        filename: String,
        outputDirectory: URL,
        metadata: DocumentMetadata?
    ) throws -> URL {
        logger.debug("Generating Excel document: \(filename).xlsx")

        let fileURL = outputDirectory.appendingPathComponent("\(filename).xlsx")

        /// Create temporary directory for XLSX structure.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        /// Parse content into rows/columns (simple CSV-like parsing).
        var rows: [[String]] = []

        /// Add metadata as header rows if present.
        if let metadata = metadata {
            rows.append([metadata.title])
            if let author = metadata.author {
                rows.append(["Author:", author])
            }
            rows.append(["Created:", metadata.createdDate.formatted(date: .long, time: .shortened)])
            if let description = metadata.description {
                rows.append(["Description:", description])
            }
            rows.append([])
        }

        /// Parse content into rows.
        let contentLines = content.components(separatedBy: .newlines)
        for line in contentLines {
            /// Try to detect tab-separated or comma-separated values.
            if line.contains("\t") {
                rows.append(line.components(separatedBy: "\t"))
            } else if line.contains(",") {
                rows.append(line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            } else {
                rows.append([line])
            }
        }

        /// Build XLSX structure.
        try createExcelDocumentStructure(at: tempDir, rows: rows)

        /// Create ZIP archive.
        try createZIPArchive(from: tempDir, to: fileURL)

        logger.debug("Excel document created: \(fileURL.path)")
        return fileURL
    }

    private func createExcelDocumentStructure(at baseURL: URL, rows: [[String]]) throws {
        /// Create directory structure.
        try FileManager.default.createDirectory(at: baseURL.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: baseURL.appendingPathComponent("xl/_rels"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: baseURL.appendingPathComponent("xl/worksheets"), withIntermediateDirectories: true)

        /// [Content_Types].xml.
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
            <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
            <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
        </Types>
        """
        try contentTypes.write(to: baseURL.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)

        /// _rels/.rels.
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """
        try rels.write(to: baseURL.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)

        /// xl/_rels/workbook.xml.rels.
        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
        </Relationships>
        """
        try workbookRels.write(to: baseURL.appendingPathComponent("xl/_rels/workbook.xml.rels"), atomically: true, encoding: .utf8)

        /// xl/workbook.xml.
        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            <sheets>
                <sheet name="Sheet1" sheetId="1" r:id="rId1"/>
            </sheets>
        </workbook>
        """
        try workbook.write(to: baseURL.appendingPathComponent("xl/workbook.xml"), atomically: true, encoding: .utf8)

        /// Build shared strings and cells.
        var sharedStrings: [String] = []
        var sharedStringMap: [String: Int] = [:]
        var cellsXML = ""

        for (rowIndex, row) in rows.enumerated() {
            let rowNum = rowIndex + 1
            var rowCells = ""

            for (colIndex, cellValue) in row.enumerated() {
                let colLetter = columnLetter(for: colIndex)
                let cellRef = "\(colLetter)\(rowNum)"

                /// Add to shared strings if not already present.
                if !sharedStringMap.keys.contains(cellValue) {
                    sharedStringMap[cellValue] = sharedStrings.count
                    sharedStrings.append(cellValue)
                }

                let stringIndex = sharedStringMap[cellValue]!
                rowCells += """
                    <c r="\(cellRef)" t="s">
                        <v>\(stringIndex)</v>
                    </c>
                """
            }

            if !rowCells.isEmpty {
                cellsXML += """
                    <row r="\(rowNum)">
                \(rowCells)
                    </row>
                """
            }
        }

        /// xl/sharedStrings.xml.
        var sharedStringsXML = ""
        for string in sharedStrings {
            sharedStringsXML += "<si><t>\(xmlEscape(string))</t></si>"
        }

        let sharedStringsFile = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="\(sharedStrings.count)" uniqueCount="\(sharedStrings.count)">
        \(sharedStringsXML)
        </sst>
        """
        try sharedStringsFile.write(to: baseURL.appendingPathComponent("xl/sharedStrings.xml"), atomically: true, encoding: .utf8)

        /// xl/worksheets/sheet1.xml.
        let worksheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
            <sheetData>
        \(cellsXML)
            </sheetData>
        </worksheet>
        """
        try worksheet.write(to: baseURL.appendingPathComponent("xl/worksheets/sheet1.xml"), atomically: true, encoding: .utf8)
    }

    // MARK: - ZIP Archive Creation

    private func createZIPArchive(from sourceURL: URL, to destinationURL: URL) throws {
        logger.debug("DOCX DEBUG: Entering createZIPArchive - source: \(sourceURL.path), dest: \(destinationURL.path)")

        /// Remove existing file if present.
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            logger.debug("DOCX DEBUG: Removing existing file at destination")
            try FileManager.default.removeItem(at: destinationURL)
        }

        /// List files in source directory before creating archive.
        logger.debug("Creating ZIP archive from: \(sourceURL.path)")
        let allFiles = try FileManager.default.subpathsOfDirectory(atPath: sourceURL.path)
        logger.debug("Found \(allFiles.count) files to add to archive: \(allFiles.joined(separator: ", "))")

        /// Create archive using throwing initializer.
        logger.debug("DOCX DEBUG: About to create Archive with URL: \(destinationURL.path)")
        let archive = try Archive(url: destinationURL, accessMode: .create)
        logger.debug("DOCX DEBUG: Archive created successfully")

        /// Add all files recursively.
        try addDirectoryToArchive(archive: archive, directoryURL: sourceURL, basePath: sourceURL.path)

        logger.debug("Archive creation complete")
    }

    private func addDirectoryToArchive(archive: Archive, directoryURL: URL, basePath: String) throws {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)

        /// Base directory URL for relative path calculation CRITICAL: Resolve symlinks to ensure path comparison works (e.g., /var vs /private/var).
        let baseURL = URL(fileURLWithPath: basePath).resolvingSymlinksInPath()

        for itemURL in contents {
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: itemURL.path, isDirectory: &isDirectory)

            /// Resolve symlinks in itemURL to match baseURL format.
            let resolvedItemURL = itemURL.resolvingSymlinksInPath()

            if isDirectory.boolValue {
                /// Recurse into subdirectory.
                try addDirectoryToArchive(archive: archive, directoryURL: resolvedItemURL, basePath: basePath)
            } else {
                /// Add file to archive using proper URL path calculation Calculate relative path using URL pathComponents.
                let fileComponents = resolvedItemURL.pathComponents
                let baseComponents = baseURL.pathComponents

                /// Find where paths diverge and build relative path.
                var relativeComponents: [String] = []
                var foundDivergence = false
                for (index, component) in fileComponents.enumerated() {
                    if index < baseComponents.count {
                        if foundDivergence || component != baseComponents[index] {
                            foundDivergence = true
                            relativeComponents.append(component)
                        }
                    } else {
                        relativeComponents.append(component)
                    }
                }

                let relativePath = relativeComponents.joined(separator: "/")

                logger.debug("Adding to archive: relativePath='\(relativePath)', file='\(resolvedItemURL.path)', basePath='\(basePath)'")
                logger.debug("File exists at itemURL: \(fileManager.fileExists(atPath: resolvedItemURL.path))")

                /// ZIPFoundation addEntry(with:relativeTo:) expects: - with: just the relative path within ZIP (e.g., "[Content_Types].xml", "word/document.xml") - relativeTo: the base directory URL where the file actually exists.
                do {
                    try archive.addEntry(with: relativePath, relativeTo: baseURL)
                    logger.debug("SUCCESS: Added '\(relativePath)' to archive")
                } catch {
                    logger.error("FAILED to add '\(relativePath)' to archive: \(error.localizedDescription)")
                    throw error
                }
            }
        }
    }

    /// Helper: Convert column index to Excel column letter (A, B, C, ..., Z, AA, AB, ...).
    private func columnLetter(for index: Int) -> String {
        var column = index
        var letter = ""
        while column >= 0 {
            letter = String(UnicodeScalar(65 + (column % 26))!) + letter
            column = (column / 26) - 1
            if column < 0 { break }
        }
        return letter
    }

    /// Helper: XML escape special characters.
    private func xmlEscape(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    // MARK: - Helper Methods

    private func resolveOutputDirectory(_ customPath: String?, workingDirectory: String? = nil) throws -> URL {
        if let customPath = customPath {
            /// Check if path is absolute or relative.
            let nsPath = customPath as NSString
            let expandedPath = nsPath.expandingTildeInPath

            /// If absolute path, use it directly.
            if expandedPath.hasPrefix("/") {
                let url = URL(fileURLWithPath: expandedPath)
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                return url
            }

            /// If relative path, resolve against working directory (not process CWD!).
            /// This ensures "workspace" becomes "~/SAM/Conversation/workspace", not "repo/workspace"
            if let workingDir = workingDirectory {
                let baseURL = URL(fileURLWithPath: (workingDir as NSString).expandingTildeInPath)
                let url = baseURL.appendingPathComponent(expandedPath)
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                return url
            } else {
                /// No working directory, treat relative path as absolute (fallback).
                let url = URL(fileURLWithPath: expandedPath)
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                return url
            }
        }

        /// Default to working directory, not ~/Downloads All MCP tools should use the conversation working directory by default.
        if let workingDir = workingDirectory {
            let url = URL(fileURLWithPath: (workingDir as NSString).expandingTildeInPath)

            /// Create directory if it doesn't exist.
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: nil
            )

            return url
        }

        /// Fallback to ~/Downloads only if no working directory provided.
        let downloadsURL = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first!

        return downloadsURL
    }

    private func sanitizeFilename(_ filename: String) -> String {
        /// Remove invalid filename characters.
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        let sanitized = filename.components(separatedBy: invalidCharacters).joined(separator: "_")

        /// Limit length.
        let maxLength = 200
        if sanitized.count > maxLength {
            let index = sanitized.index(sanitized.startIndex, offsetBy: maxLength)
            return String(sanitized[..<index])
        }

        return sanitized
    }

    // MARK: - Plain Text Generation

    /// Generates a plain text file.
    private func generatePlainText(
        content: String,
        filename: String,
        outputDirectory: URL
    ) throws -> URL {
        logger.debug("Generating plain text document: \(filename)")

        let fileURL = outputDirectory.appendingPathComponent("\(filename).txt")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        return fileURL
    }
}

public struct DocumentMetadata {
    public let title: String
    public let author: String?
    public let description: String?
    public let createdDate: Date
    public let tags: [String]

    public init(
        title: String,
        author: String? = nil,
        description: String? = nil,
        createdDate: Date = Date(),
        tags: [String] = []
    ) {
        self.title = title
        self.author = author
        self.description = description
        self.createdDate = createdDate
        self.tags = tags
    }
}

public enum DocumentGeneratorError: Error, LocalizedError {
    case writeFailed(String)
    case conversionFailed(String)
    case invalidPath(String)
    case invalidFormat(String)

    public var errorDescription: String? {
        switch self {
        case .writeFailed(let message): return "Failed to write document: \(message)"
        case .conversionFailed(let message): return "Failed to convert document: \(message)"
        case .invalidPath(let message): return "Invalid path: \(message)"
        case .invalidFormat(let message): return "Invalid format: \(message)"
        }
    }
}
