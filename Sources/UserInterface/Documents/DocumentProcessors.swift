// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import PDFKit
import Vision
import UniformTypeIdentifiers
import ZIPFoundation
import Logging

/// Page content structure for page-aware chunking.
public struct PageContent {
    let pageNumber: Int
    let text: String
}

/// Extracted content structure from document processing.
public struct DocumentExtractedContent {
    let text: String
    let metadata: [String: String]
    let pages: [PageContent]?
    let formattingMetadata: FormattingMetadata?

    public init(text: String, metadata: [String: String] = [:], pages: [PageContent]? = nil, formattingMetadata: FormattingMetadata? = nil) {
        self.text = text
        self.metadata = metadata
        self.pages = pages
        self.formattingMetadata = formattingMetadata
    }
}

/// PDF Document Processor with OCR fallback Extracts text from PDF documents using PDFKit with Vision framework OCR as fallback.
class PDFDocumentProcessor: DocumentProcessor, @unchecked Sendable {
    private let logger = Logger(label: "com.sam.documents.PDFProcessor")

    func extractContent(from url: URL, contentType: UTType) async throws -> DocumentExtractedContent {
        logger.debug("Processing PDF: \(url.lastPathComponent)")

        guard let pdfDocument = PDFDocument(url: url) else {
            throw DocumentImportError.processingFailed("Could not load PDF document")
        }

        var extractedText = ""
        var metadata: [String: String] = [:]

        /// Extract metadata.
        if let title = pdfDocument.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String {
            metadata["title"] = title
        }
        if let author = pdfDocument.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String {
            metadata["author"] = author
        }
        if let subject = pdfDocument.documentAttributes?[PDFDocumentAttribute.subjectAttribute] as? String {
            metadata["subject"] = subject
        }

        metadata["pageCount"] = String(pdfDocument.pageCount)

        /// Extract text from each page (preserve page boundaries for better chunking).
        var pages: [PageContent] = []

        for pageIndex in 0..<pdfDocument.pageCount {
            if let page = pdfDocument.page(at: pageIndex) {
                var pageText = ""

                if let text = page.string {
                    pageText = text
                } else {
                    /// Fallback to OCR for pages without selectable text.
                    logger.debug("Using OCR for page \(pageIndex + 1)")
                    if let ocrText = try await performOCR(on: page) {
                        pageText = ocrText
                    }
                }

                /// Store each page separately with page number.
                if !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pages.append(PageContent(
                        pageNumber: pageIndex + 1,
                        text: pageText
                    ))
                }
            }
        }

        /// Concatenate for backward compatibility, but preserve page info.
        extractedText = pages.map { $0.text }.joined(separator: "\n\n")

        /// Extract formatting metadata for roundtrip preservation.
        let formattingMetadata = extractFormattingMetadata(from: pdfDocument, metadata: &metadata)

        logger.debug("PDF processed: \(pages.count) pages, \(extractedText.count) characters")

        return DocumentExtractedContent(
            text: extractedText.trimmingCharacters(in: .whitespacesAndNewlines),
            metadata: metadata,
            pages: pages,
            formattingMetadata: formattingMetadata
        )
    }

    private func performOCR(on page: PDFPage) async throws -> String? {
        let pageImage = page.thumbnail(of: CGSize(width: 612, height: 792), for: .mediaBox)

        guard let cgImage = pageImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let recognizedText = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }.joined(separator: "\n")

                continuation.resume(returning: recognizedText)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Extract formatting metadata from PDF for roundtrip preservation.
    private func extractFormattingMetadata(from pdfDocument: PDFDocument, metadata: inout [String: String]) -> FormattingMetadata {
        var formattingMetadata = FormattingMetadata.defaultMetadata(for: .pdf)

        /// Extract page size from first page.
        if let firstPage = pdfDocument.page(at: 0) {
            let bounds = firstPage.bounds(for: .mediaBox)
            formattingMetadata.pageSize = PageSizeMetadata(
                width: Double(bounds.width),
                height: Double(bounds.height),
                unit: "points"
            )
        }

        /// Store PDF-specific metadata.
        formattingMetadata.preservedRawMetadata["pdf_version"] = metadata["pdf_version"] ?? "1.4"
        formattingMetadata.preservedRawMetadata["producer"] = pdfDocument.documentAttributes?[PDFDocumentAttribute.producerAttribute] as? String ?? ""
        formattingMetadata.preservedRawMetadata["creator"] = pdfDocument.documentAttributes?[PDFDocumentAttribute.creatorAttribute] as? String ?? ""

        logger.debug("Extracted formatting metadata from PDF: pageSize=\(formattingMetadata.pageSize?.width ?? 0)x\(formattingMetadata.pageSize?.height ?? 0)")

        return formattingMetadata
    }
}

/// Text Document Processor Handles plain text, markdown, RTF, and code files.
class TextDocumentProcessor: DocumentProcessor, @unchecked Sendable {
    private let logger = Logger(label: "com.sam.documents.TextProcessor")

    func extractContent(from url: URL, contentType: UTType) async throws -> DocumentExtractedContent {
        logger.debug("Processing text file: \(url.lastPathComponent)")

        let data = try Data(contentsOf: url)
        var text: String
        var metadata: [String: String] = [:]

        /// Handle different text encodings.
        if let utf8Text = String(data: data, encoding: .utf8) {
            text = utf8Text
        } else if let utf16Text = String(data: data, encoding: .utf16) {
            text = utf16Text
        } else if let asciiText = String(data: data, encoding: .ascii) {
            text = asciiText
        } else {
            throw DocumentImportError.processingFailed("Could not decode text file with supported encodings")
        }

        /// Add file-specific metadata.
        metadata["encoding"] = "UTF-8"
        metadata["lineCount"] = String(text.components(separatedBy: .newlines).count)
        metadata["wordCount"] = String(text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count)

        /// Detect programming language for code files.
        if contentType.conforms(to: UTType("public.source-code") ?? .data) {
            metadata["language"] = detectProgrammingLanguage(from: url.pathExtension)
        }

        logger.debug("Text file processed: \(text.count) characters, \(metadata["lineCount"] ?? "0") lines")

        return DocumentExtractedContent(text: text, metadata: metadata)
    }

    private func detectProgrammingLanguage(from extension: String) -> String {
        switch `extension`.lowercased() {
        case "swift": return "Swift"
        case "py": return "Python"
        case "js", "mjs": return "JavaScript"
        case "ts": return "TypeScript"
        case "java": return "Java"
        case "cpp", "cxx", "cc": return "C++"
        case "c": return "C"
        case "h": return "C/C++ Header"
        case "m": return "Objective-C"
        case "go": return "Go"
        case "rs": return "Rust"
        case "php": return "PHP"
        case "rb": return "Ruby"
        case "sh": return "Shell Script"
        case "sql": return "SQL"
        case "html": return "HTML"
        case "css": return "CSS"
        case "xml": return "XML"
        case "json": return "JSON"
        case "yaml", "yml": return "YAML"
        case "md": return "Markdown"
        default: return "Unknown"
        }
    }
}

/// Image Document Processor with OCR Extracts text from images using Vision framework OCR.
class ImageDocumentProcessor: DocumentProcessor, @unchecked Sendable {
    private let logger = Logger(label: "com.sam.documents.ImageProcessor")

    func extractContent(from url: URL, contentType: UTType) async throws -> DocumentExtractedContent {
        logger.debug("Processing image: \(url.lastPathComponent)")

        let data = try Data(contentsOf: url)
        guard let image = NSImage(data: data) else {
            throw DocumentImportError.processingFailed("Could not load image")
        }

        var metadata: [String: String] = [:]
        metadata["imageSize"] = "\(Int(image.size.width))x\(Int(image.size.height))"
        metadata["format"] = contentType.preferredFilenameExtension ?? "unknown"

        /// Perform OCR on the image.
        let extractedText = try await performImageOCR(data: data)

        logger.debug("Image processed: \(extractedText.count) characters extracted via OCR")

        return DocumentExtractedContent(
            text: extractedText,
            metadata: metadata
        )
    }

    private func performImageOCR(data: Data) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let recognizedText = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }.joined(separator: "\n")

                continuation.resume(returning: recognizedText)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(data: data, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Office Document Processor Handles Microsoft Office documents (DOCX, Excel) - basic implementation.
class OfficeDocumentProcessor: DocumentProcessor, @unchecked Sendable {
    private let logger = Logger(label: "com.sam.documents.OfficeProcessor")

    func extractContent(from url: URL, contentType: UTType) async throws -> DocumentExtractedContent {
        logger.debug("Processing Office document: \(url.lastPathComponent)")

        /// Note: Full Office document parsing would require additional dependencies This is a basic implementation that extracts what it can.

        var metadata: [String: String] = [:]
        metadata["documentType"] = "Microsoft Office Document"
        metadata["note"] = "Basic text extraction - full formatting not preserved"

        /// For now, we'll attempt basic ZIP-based extraction for modern Office formats.
        if contentType.identifier.contains("openxmlformats") {
            return try await extractFromOpenXML(url: url, metadata: metadata)
        } else {
            /// Legacy formats would need specialized handling.
            throw DocumentImportError.processingFailed("Legacy Office formats not yet supported")
        }
    }

    private func extractFromOpenXML(url: URL, metadata: [String: String]) async throws -> DocumentExtractedContent {
        /// Modern Office documents (.docx, .xlsx) are ZIP archives containing XML files.
        logger.debug("Opening Office document as ZIP archive: \(url.lastPathComponent)")

        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw DocumentImportError.processingFailed("Could not open Office document as ZIP archive: \(error.localizedDescription)")
        }

        var metadata = metadata
        var extractedText = ""

        /// Detect document type and extract accordingly.
        if url.pathExtension.lowercased() == "docx" {
            extractedText = try await extractWordDocument(from: archive, metadata: &metadata)
        } else if url.pathExtension.lowercased() == "xlsx" {
            extractedText = try await extractExcelDocument(from: archive, metadata: &metadata)
        } else {
            throw DocumentImportError.processingFailed("Unsupported Office document format: \(url.pathExtension)")
        }

        logger.debug("Office document processed: \(extractedText.count) characters extracted")

        return DocumentExtractedContent(
            text: extractedText.trimmingCharacters(in: .whitespacesAndNewlines),
            metadata: metadata
        )
    }

    /// Extract text from Word document (.docx).
    private func extractWordDocument(from archive: Archive, metadata: inout [String: String]) async throws -> String {
        /// Word documents store main content in word/document.xml.
        guard let documentEntry = archive["word/document.xml"] else {
            throw DocumentImportError.processingFailed("Missing word/document.xml in DOCX archive")
        }

        /// Extract XML data.
        var documentXML = Data()
        _ = try archive.extract(documentEntry) { data in
            documentXML.append(data)
        }

        logger.debug("Extracted word/document.xml: \(documentXML.count) bytes")

        /// Parse XML document.
        let xmlDoc = try XMLDocument(data: documentXML)

        /// Word uses namespace: http://schemas.openxmlformats.org/wordprocessingml/2006/main We need to register the namespace prefix for XPath queries.
        if let rootElement = xmlDoc.rootElement() {
            /// Check if namespace is defined.
            for namespace in rootElement.namespaces ?? [] {
                if namespace.stringValue == "http://schemas.openxmlformats.org/wordprocessingml/2006/main" {
                    /// Namespace exists, we can use it.
                    break
                }
            }
        }

        /// Extract all text nodes - try with namespace prefix first, fallback to local name.
        var textNodes: [XMLNode] = []
        do {
            textNodes = try xmlDoc.nodes(forXPath: "//w:t")
        } catch {
            /// Fallback: try without namespace prefix (some docs may not use it).
            textNodes = try xmlDoc.nodes(forXPath: "//*[local-name()='t']")
        }

        var paragraphs: [String] = []
        var currentParagraph = ""

        /// Extract text while attempting to preserve paragraph structure Note: This is simplified - full formatting would require tracking <w:p> (paragraph) boundaries.
        for textNode in textNodes {
            if let textContent = textNode.stringValue {
                currentParagraph += textContent

                /// Check if we hit end of paragraph (simplified heuristic) In reality, we'd track parent <w:p> elements.
                if textContent.hasSuffix(".") || textContent.hasSuffix("!") || textContent.hasSuffix("?") {
                    paragraphs.append(currentParagraph)
                    currentParagraph = ""
                }
            }
        }

        /// Add any remaining text.
        if !currentParagraph.isEmpty {
            paragraphs.append(currentParagraph)
        }

        /// Extract table content (<w:tbl> elements).
        var tableNodes: [XMLNode] = []
        do {
            tableNodes = try xmlDoc.nodes(forXPath: "//w:tbl")
        } catch {
            /// Fallback: try without namespace prefix.
            tableNodes = try xmlDoc.nodes(forXPath: "//*[local-name()='tbl']")
        }

        if !tableNodes.isEmpty {
            metadata["tableCount"] = String(tableNodes.count)
            logger.debug("Found \(tableNodes.count) tables in document")

            /// Extract table text.
            for tableNode in tableNodes {
                var tableCells: [XMLNode] = []
                do {
                    tableCells = try tableNode.nodes(forXPath: ".//w:t")
                } catch {
                    /// Fallback: try without namespace prefix.
                    tableCells = try tableNode.nodes(forXPath: ".//*[local-name()='t']")
                }
                let tableText = tableCells.compactMap { $0.stringValue }.joined(separator: " | ")
                if !tableText.isEmpty {
                    paragraphs.append("[Table: \(tableText)]")
                }
            }
        }

        metadata["documentType"] = "Microsoft Word"
        metadata["paragraphCount"] = String(paragraphs.count)

        return paragraphs.joined(separator: "\n\n")
    }

    /// Extract text from Excel spreadsheet (.xlsx).
    private func extractExcelDocument(from archive: Archive, metadata: inout [String: String]) async throws -> String {
        /// Excel stores shared strings in xl/sharedStrings.xml And sheet data in xl/worksheets/sheet*.xml.

        /// Extract shared strings (common text values used across sheets).
        var sharedStrings: [String] = []
        if let sharedStringsEntry = archive["xl/sharedStrings.xml"] {
            var sharedStringsData = Data()
            _ = try archive.extract(sharedStringsEntry) { data in
                sharedStringsData.append(data)
            }

            let xmlDoc = try XMLDocument(data: sharedStringsData)
            let stringNodes = try xmlDoc.nodes(forXPath: "//t")  // <t> elements contain text
            sharedStrings = stringNodes.compactMap { $0.stringValue }

            logger.debug("Extracted \(sharedStrings.count) shared strings")
        }

        /// Find all worksheet entries.
        var worksheetText: [String] = []
        var sheetCount = 0

        for entry in archive where entry.path.hasPrefix("xl/worksheets/sheet") && entry.path.hasSuffix(".xml") {
            sheetCount += 1

            var sheetData = Data()
            _ = try archive.extract(entry) { data in
                sheetData.append(data)
            }

            let xmlDoc = try XMLDocument(data: sheetData)

            /// Extract cell values Cells with shared strings reference index via <c t="s"><v>index</v></c> Cells with direct values use <c><v>value</v></c>.
            let cellNodes = try xmlDoc.nodes(forXPath: "//c")

            var sheetCells: [String] = []

            for cellNode in cellNodes {
                if let cell = cellNode as? XMLElement {
                    /// Check if cell uses shared string.
                    let cellType = cell.attribute(forName: "t")?.stringValue

                    if let valueNode = try cell.nodes(forXPath: "./v").first {
                        if let valueString = valueNode.stringValue {
                            if cellType == "s", let index = Int(valueString), index < sharedStrings.count {
                                /// Shared string reference.
                                sheetCells.append(sharedStrings[index])
                            } else {
                                /// Direct value.
                                sheetCells.append(valueString)
                            }
                        }
                    }
                }
            }

            if !sheetCells.isEmpty {
                worksheetText.append("[Sheet \(sheetCount)]\n" + sheetCells.joined(separator: " | "))
            }
        }

        metadata["documentType"] = "Microsoft Excel"
        metadata["sheetCount"] = String(sheetCount)
        metadata["note"] = "Cell values extracted (formatting not preserved)"

        logger.debug("Extracted \(sheetCount) sheets from Excel document")

        return worksheetText.joined(separator: "\n\n")
    }
}
