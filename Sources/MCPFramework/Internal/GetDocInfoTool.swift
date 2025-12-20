// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import Logging

/// MCP Tool for extracting comprehensive document and file metadata Provides universal metadata extraction for various file types including PDFs, images, text files, and more.
public class GetDocInfoTool: MCPTool, @unchecked Sendable {
    public let name = "get_doc_info"
    public let description = "Extract comprehensive metadata from documents and files. Get page counts, dimensions, file sizes, dates, author info, and more. Supports PDFs, images, text files, and all common document formats."

    public var parameters: [String: MCPToolParameter] {
        [
            "file_path": MCPToolParameter(
                type: .string,
                description: "Absolute path to the file (supports tilde expansion like ~/Documents/file.pdf)",
                required: true
            ),
            "include_extended_metadata": MCPToolParameter(
                type: .boolean,
                description: "Include detailed format-specific metadata (e.g., EXIF data for images, PDF version info). Default: false",
                required: false
            )
        ]
    }

    private let logger = Logger(label: "com.sam.mcp.GetDocInfoTool")

    public init() {}

    public func initialize() async throws {
        logger.debug("[GetDocInfoTool] Initialized")
    }

    public func validateParameters(_ params: [String: Any]) throws -> Bool {
        guard let filePath = params["file_path"] as? String, !filePath.isEmpty else {
            throw MCPError.invalidParameters("file_path parameter is required and must be a non-empty string")
        }
        return true
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        logger.debug("Executing get_doc_info tool")

        guard let filePath = parameters["file_path"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "{\"success\": false, \"error\": \"Missing required parameter: file_path\"}")
            )
        }

        let includeExtended = parameters["include_extended_metadata"] as? Bool ?? false

        /// Expand tilde in path.
        let expandedPath = NSString(string: filePath).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)

        logger.debug("Extracting metadata for: \(expandedPath) (extended: \(includeExtended))")

        /// Check file exists.
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            let errorResult = [
                "success": false,
                "error": "File not found: \(expandedPath)",
                "file_path": expandedPath
            ] as [String: Any]

            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: formatJSON(errorResult))
            )
        }

        /// Extract metadata.
        var metadata: [String: Any] = [
            "success": true,
            "file_path": expandedPath,
            "file_name": url.lastPathComponent
        ]

        /// Basic file attributes.
        if let basicMetadata = extractBasicMetadata(url: url) {
            metadata.merge(basicMetadata) { _, new in new }
        }

        /// Type-specific metadata.
        let fileType = metadata["file_type"] as? String ?? ""

        if fileType.contains("pdf") {
            if let pdfMetadata = extractPDFMetadata(url: url, includeExtended: includeExtended) {
                metadata.merge(pdfMetadata) { _, new in new }
            }
        } else if fileType.hasPrefix("public.image") || fileType.contains("image") {
            if let imageMetadata = extractImageMetadata(url: url, includeExtended: includeExtended) {
                metadata.merge(imageMetadata) { _, new in new }
            }
        } else if fileType.contains("text") || fileType.contains("plain") {
            if let textMetadata = extractTextMetadata(url: url) {
                metadata.merge(textMetadata) { _, new in new }
            }
        }

        logger.debug("Successfully extracted metadata for \(url.lastPathComponent)")

        return MCPToolResult(
            toolName: name,
            success: true,
            output: MCPOutput(content: formatJSON(metadata), mimeType: "application/json")
        )
    }

    // MARK: - Actions

    private func extractBasicMetadata(url: URL) -> [String: Any]? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)

            var metadata: [String: Any] = [:]

            /// File size.
            if let size = attributes[.size] as? Int64 {
                metadata["file_size"] = size
                metadata["file_size_human"] = formatFileSize(size)
            }

            /// Dates.
            if let creationDate = attributes[.creationDate] as? Date {
                metadata["created_at"] = ISO8601DateFormatter().string(from: creationDate)
            }

            if let modificationDate = attributes[.modificationDate] as? Date {
                metadata["modified_at"] = ISO8601DateFormatter().string(from: modificationDate)
            }

            /// Access date (if available).
            if let accessDate = attributes[.modificationDate] as? Date {
                metadata["accessed_at"] = ISO8601DateFormatter().string(from: accessDate)
            }

            /// Permissions.
            if let posixPermissions = attributes[.posixPermissions] as? NSNumber {
                metadata["permissions"] = formatPermissions(posixPermissions.uint16Value)
            }

            /// Readability/writability.
            metadata["is_readable"] = FileManager.default.isReadableFile(atPath: url.path)
            metadata["is_writable"] = FileManager.default.isWritableFile(atPath: url.path)
            metadata["is_executable"] = FileManager.default.isExecutableFile(atPath: url.path)

            /// UTI (Uniform Type Identifier).
            if let uti = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier {
                metadata["file_type"] = uti

                /// Human-readable type description.
                if let type = UTType(uti) {
                    metadata["type_description"] = type.localizedDescription ?? uti
                }
            }

            return metadata
        } catch {
            logger.warning("Failed to extract basic metadata: \(error)")
            return nil
        }
    }

    private func extractPDFMetadata(url: URL, includeExtended: Bool) -> [String: Any]? {
        guard let pdfDocument = PDFDocument(url: url) else {
            logger.warning("Failed to open PDF document")
            return nil
        }

        var metadata: [String: Any] = [:]

        /// Page count.
        metadata["page_count"] = pdfDocument.pageCount

        /// PDF attributes.
        if let attributes = pdfDocument.documentAttributes {
            /// Standard PDF metadata.
            if let title = attributes[PDFDocumentAttribute.titleAttribute] as? String {
                metadata["title"] = title
            }

            if let author = attributes[PDFDocumentAttribute.authorAttribute] as? String {
                metadata["author"] = author
            }

            if let subject = attributes[PDFDocumentAttribute.subjectAttribute] as? String {
                metadata["subject"] = subject
            }

            if let keywords = attributes[PDFDocumentAttribute.keywordsAttribute] as? [String] {
                metadata["keywords"] = keywords
            }

            if let creator = attributes[PDFDocumentAttribute.creatorAttribute] as? String {
                metadata["creator"] = creator
            }

            if let producer = attributes[PDFDocumentAttribute.producerAttribute] as? String {
                metadata["producer"] = producer
            }

            if let creationDate = attributes[PDFDocumentAttribute.creationDateAttribute] as? Date {
                metadata["pdf_creation_date"] = ISO8601DateFormatter().string(from: creationDate)
            }

            if let modificationDate = attributes[PDFDocumentAttribute.modificationDateAttribute] as? Date {
                metadata["pdf_modification_date"] = ISO8601DateFormatter().string(from: modificationDate)
            }

            /// Extended metadata.
            if includeExtended {
                var extendedMetadata: [String: Any] = [:]

                /// PDF version.
                extendedMetadata["pdf_version"] = pdfDocument.majorVersion
                extendedMetadata["pdf_minor_version"] = pdfDocument.minorVersion

                /// Encryption.
                extendedMetadata["is_encrypted"] = pdfDocument.isEncrypted
                extendedMetadata["is_locked"] = pdfDocument.isLocked

                /// Page size (first page).
                if pdfDocument.pageCount > 0, let firstPage = pdfDocument.page(at: 0) {
                    let bounds = firstPage.bounds(for: .mediaBox)
                    extendedMetadata["page_width_points"] = bounds.width
                    extendedMetadata["page_height_points"] = bounds.height
                    extendedMetadata["page_width_inches"] = bounds.width / 72.0
                    extendedMetadata["page_height_inches"] = bounds.height / 72.0
                }

                /// All PDF attributes for advanced use.
                extendedMetadata["all_pdf_attributes"] = attributes.mapValues { "\($0)" }

                metadata["extended_metadata"] = extendedMetadata
            }
        }

        return metadata
    }

    private func extractImageMetadata(url: URL, includeExtended: Bool) -> [String: Any]? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            logger.warning("Failed to create image source")
            return nil
        }

        var metadata: [String: Any] = [:]

        /// Image properties.
        if let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] {
            /// Dimensions.
            if let width = properties[kCGImagePropertyPixelWidth as String] as? Int {
                metadata["width"] = width
            }

            if let height = properties[kCGImagePropertyPixelHeight as String] as? Int {
                metadata["height"] = height
            }

            /// DPI.
            if let dpiWidth = properties[kCGImagePropertyDPIWidth as String] as? Double {
                metadata["dpi_width"] = dpiWidth
            }

            if let dpiHeight = properties[kCGImagePropertyDPIHeight as String] as? Double {
                metadata["dpi_height"] = dpiHeight
            }

            /// Color model.
            if let colorModel = properties[kCGImagePropertyColorModel as String] as? String {
                metadata["color_model"] = colorModel
            }

            /// Depth.
            if let depth = properties[kCGImagePropertyDepth as String] as? Int {
                metadata["bit_depth"] = depth
            }

            /// Extended metadata (EXIF, etc.).
            if includeExtended {
                var extendedMetadata: [String: Any] = [:]

                /// EXIF data.
                if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                    extendedMetadata["exif"] = exif
                }

                /// TIFF data.
                if let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
                    extendedMetadata["tiff"] = tiff
                }

                /// GPS data.
                if let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] {
                    extendedMetadata["gps"] = gps
                }

                /// IPTC data.
                if let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] {
                    extendedMetadata["iptc"] = iptc
                }

                metadata["extended_metadata"] = extendedMetadata
            }
        }

        return metadata
    }

    private func extractTextMetadata(url: URL) -> [String: Any]? {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)

            var metadata: [String: Any] = [:]

            /// Character count.
            metadata["character_count"] = content.count

            /// Line count.
            let lineCount = content.components(separatedBy: .newlines).count
            metadata["line_count"] = lineCount

            /// Word count (approximate).
            let words = content.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            metadata["word_count"] = words.count

            /// Encoding.
            metadata["encoding"] = "UTF-8"

            return metadata
        } catch {
            logger.warning("Failed to extract text metadata: \(error)")
            /// Try other encodings.
            if let content = try? String(contentsOf: url, encoding: .ascii) {
                return [
                    "character_count": content.count,
                    "encoding": "ASCII"
                ]
            }
            return nil
        }
    }

    // MARK: - Helper Methods

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatPermissions(_ mode: UInt16) -> String {
        let owner = formatPermissionTriple((mode >> 6) & 0o7)
        let group = formatPermissionTriple((mode >> 3) & 0o7)
        let other = formatPermissionTriple(mode & 0o7)
        return "\(owner)\(group)\(other)"
    }

    private func formatPermissionTriple(_ triple: UInt16) -> String {
        let r = (triple & 0o4) != 0 ? "r" : "-"
        let w = (triple & 0o2) != 0 ? "w" : "-"
        let x = (triple & 0o1) != 0 ? "x" : "-"
        return "\(r)\(w)\(x)"
    }

    private func formatJSON(_ object: [String: Any]) -> String {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return "{\"error\": \"Failed to serialize response\"}"
        }
        return jsonString
    }
}
