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

/// CSV/TSV Document Processor - preserves tabular structure with headers and rows.
class CSVDocumentProcessor: DocumentProcessor, @unchecked Sendable {
    private let logger = Logger(label: "com.sam.documents.CSVProcessor")

    func extractContent(from url: URL, contentType: UTType) async throws -> DocumentExtractedContent {
        logger.debug("Processing CSV/TSV: \(url.lastPathComponent)")

        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw DocumentImportError.processingFailed("Could not decode CSV file")
        }

        var metadata: [String: String] = [:]
        metadata["documentType"] = "Spreadsheet (CSV/TSV)"

        /// Detect delimiter (comma, tab, semicolon)
        let delimiter = detectDelimiter(text)
        metadata["delimiter"] = delimiter == "\t" ? "tab" : String(delimiter)

        /// Parse CSV preserving structure
        let rows = parseCSV(text, delimiter: delimiter)
        guard !rows.isEmpty else {
            throw DocumentImportError.processingFailed("CSV file is empty or could not be parsed")
        }

        metadata["rowCount"] = String(rows.count)
        metadata["columnCount"] = String(rows.first?.count ?? 0)

        /// Build pipe-delimited output preserving row structure
        var outputLines: [String] = []

        /// First row is treated as headers
        if let headers = rows.first {
            outputLines.append(headers.joined(separator: " | "))
            outputLines.append(String(repeating: "-", count: outputLines[0].count))
        }

        for row in rows.dropFirst() {
            outputLines.append(row.joined(separator: " | "))
        }

        let output = outputLines.joined(separator: "\n")
        metadata["note"] = "Tabular data preserved with row/column structure"

        logger.debug("CSV processed: \(rows.count) rows, \(rows.first?.count ?? 0) columns")

        return DocumentExtractedContent(text: output, metadata: metadata)
    }

    /// Detect the most likely delimiter in the content.
    private func detectDelimiter(_ text: String) -> Character {
        let firstLines = text.components(separatedBy: .newlines).prefix(5).joined(separator: "\n")
        let commas = firstLines.filter { $0 == "," }.count
        let tabs = firstLines.filter { $0 == "\t" }.count
        let semicolons = firstLines.filter { $0 == ";" }.count

        if tabs > commas && tabs > semicolons { return "\t" }
        if semicolons > commas { return ";" }
        return ","
    }

    /// Parse CSV handling quoted fields.
    private func parseCSV(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var currentField = ""
        var currentRow: [String] = []
        var inQuotes = false

        for char in text {
            if inQuotes {
                if char == "\"" {
                    /// Check for escaped quote
                    inQuotes = false
                } else {
                    currentField.append(char)
                }
            } else {
                switch char {
                case "\"":
                    inQuotes = true
                case delimiter:
                    currentRow.append(currentField.trimmingCharacters(in: .whitespaces))
                    currentField = ""
                case "\n", "\r":
                    if !currentField.isEmpty || !currentRow.isEmpty {
                        currentRow.append(currentField.trimmingCharacters(in: .whitespaces))
                        rows.append(currentRow)
                        currentRow = []
                        currentField = ""
                    }
                default:
                    currentField.append(char)
                }
            }
        }

        /// Handle last row without trailing newline
        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField.trimmingCharacters(in: .whitespaces))
            rows.append(currentRow)
        }

        return rows
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

    /// Extract text from Excel spreadsheet (.xlsx) preserving row/column structure.
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
        var totalRows = 0

        /// Sort sheet entries so they appear in order
        let sheetEntries = archive.sorted { $0.path < $1.path }
            .filter { $0.path.hasPrefix("xl/worksheets/sheet") && $0.path.hasSuffix(".xml") }

        for entry in sheetEntries {
            sheetCount += 1

            var sheetData = Data()
            _ = try archive.extract(entry) { data in
                sheetData.append(data)
            }

            let xmlDoc = try XMLDocument(data: sheetData)

            /// Parse by rows to preserve tabular structure
            let rowNodes = try xmlDoc.nodes(forXPath: "//row")
            var maxColumn = 0
            var rows: [(rowNum: Int, cells: [(col: Int, value: String)])] = []

            for rowNode in rowNodes {
                guard let rowElement = rowNode as? XMLElement else { continue }
                let rowNum = Int(rowElement.attribute(forName: "r")?.stringValue ?? "0") ?? 0
                let cellNodes = try rowElement.nodes(forXPath: "./c")

                var rowCells: [(col: Int, value: String)] = []

                for cellNode in cellNodes {
                    guard let cell = cellNode as? XMLElement else { continue }
                    let cellRef = cell.attribute(forName: "r")?.stringValue ?? ""
                    let cellType = cell.attribute(forName: "t")?.stringValue
                    let colIndex = columnIndex(from: cellRef)

                    if colIndex > maxColumn { maxColumn = colIndex }

                    var cellValue = ""

                    if let valueNode = try cell.nodes(forXPath: "./v").first,
                       let valueString = valueNode.stringValue {
                        if cellType == "s", let index = Int(valueString), index < sharedStrings.count {
                            cellValue = sharedStrings[index]
                        } else {
                            cellValue = valueString
                        }
                    } else if let inlineNode = try cell.nodes(forXPath: "./is/t").first {
                        /// Handle inline strings
                        cellValue = inlineNode.stringValue ?? ""
                    }

                    if !cellValue.isEmpty {
                        rowCells.append((col: colIndex, value: cellValue))
                    }
                }

                if !rowCells.isEmpty {
                    rows.append((rowNum: rowNum, cells: rowCells))
                }
            }

            if rows.isEmpty { continue }
            totalRows += rows.count

            /// Build pipe-delimited table with proper column alignment
            var sheetLines: [String] = ["[Sheet \(sheetCount)]"]

            for row in rows {
                var columns = Array(repeating: "", count: maxColumn + 1)
                for cell in row.cells {
                    if cell.col <= maxColumn {
                        columns[cell.col] = cell.value
                    }
                }
                /// Trim trailing empty columns for this row
                while columns.last?.isEmpty == true { columns.removeLast() }
                sheetLines.append(columns.joined(separator: " | "))
            }

            worksheetText.append(sheetLines.joined(separator: "\n"))
        }

        metadata["documentType"] = "Microsoft Excel"
        metadata["sheetCount"] = String(sheetCount)
        metadata["totalRows"] = String(totalRows)
        metadata["note"] = "Tabular data preserved with row/column structure"

        logger.debug("Extracted \(sheetCount) sheets, \(totalRows) rows from Excel document")

        return worksheetText.joined(separator: "\n\n")
    }

    /// Convert Excel column reference (e.g., "A", "B", "AA") to zero-based index.
    private func columnIndex(from cellRef: String) -> Int {
        let letters = cellRef.prefix(while: { $0.isLetter })
        var index = 0
        for char in letters.uppercased() {
            index = index * 26 + Int(char.asciiValue! - Character("A").asciiValue!) + 1
        }
        return index - 1
    }
}
