// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import XCTest
@testable import UserInterface
@testable import ConfigurationSystem

/// Regression tests for PDF generation. Pins the bug where direct PDF
/// generation produced blank pages because the manual CGPDFContext +
/// displayIgnoringOpacity approach failed for off-screen NSTextView.
///
/// The fix replaced that path with NSPrintOperation configured to save
/// directly to a file (jobDisposition = .save, no print panel). These tests
/// verify the generated PDF file is valid (has %PDF header, non-zero
/// size, expected page count where verifiable).
@MainActor
final class PDFGenerationTests: XCTestCase {

    /// Generated PDFs should be non-empty and start with the PDF magic bytes.
    func testGeneratePDF_CreatesValidPDFFile() async throws {
        let message = EnhancedMessage(
            content: "Hello world - this is a test message with enough content to verify the PDF renders correctly.",
            isFromUser: true,
            timestamp: Date()
        )

        let url = try await SimplePDFGenerator.generatePDF(
            messages: [message],
            conversationTitle: "Test",
            modelName: "test-model"
        )

        // File exists at the returned URL
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "PDF file should exist")

        // File has non-zero size
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = attributes[.size] as? Int ?? 0
        XCTAssertGreaterThan(fileSize, 100, "PDF should have meaningful content, got \(fileSize) bytes")

        // File starts with %PDF magic bytes
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = handle.readData(ofLength: 5)
        XCTAssertEqual(String(data: header, encoding: .ascii), "%PDF-", "File should start with PDF magic bytes")

        // Cleanup
        try? FileManager.default.removeItem(at: url)
    }

    /// Empty message list should produce a valid PDF (just a title page).
    func testGeneratePDF_EmptyMessages_ProducesValidPDF() async throws {
        let url = try await SimplePDFGenerator.generatePDF(
            messages: [],
            conversationTitle: "Empty Conversation",
            modelName: nil
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = attributes[.size] as? Int ?? 0
        XCTAssertGreaterThan(fileSize, 100, "Even empty PDF should have header + title page")

        try? FileManager.default.removeItem(at: url)
    }

    /// Multiple messages should produce a multi-page PDF (or at least a valid
    /// PDF with enough content to span multiple pages).
    func testGeneratePDF_MultipleMessages_ProducesMultiPagePDF() async throws {
        var messages: [EnhancedMessage] = []
        for i in 0..<5 {
            let message = EnhancedMessage(
                content: String(repeating: "This is a longer test message to ensure the content needs multiple pages. ", count: 20) + " (\(i))",
                isFromUser: i % 2 == 0,
                timestamp: Date()
            )
            messages.append(message)
        }

        let url = try await SimplePDFGenerator.generatePDF(
            messages: messages,
            conversationTitle: "Multi-Message Test",
            modelName: "test-model"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = attributes[.size] as? Int ?? 0

        // Multi-page content should produce a larger PDF than a single page
        XCTAssertGreaterThan(fileSize, 500, "Multi-message PDF should have substantial content")

        // Verify PDF structure has multiple pages by counting "/Type /Page" markers
        let pdfData = FileManager.default.contents(atPath: url.path) ?? Data()
        let pdfString = String(data: pdfData, encoding: .isoLatin1) ?? ""
        let pageCount = pdfString.components(separatedBy: "/Type /Page").count - 1
        XCTAssertGreaterThan(pageCount, 1, "Multi-message content should produce multiple pages, got \(pageCount)")

        try? FileManager.default.removeItem(at: url)
    }

    /// Filename should include sanitized conversation title and a timestamp.
    func testGeneratePDF_FilenameIncludesTitleAndTimestamp() async throws {
        let message = EnhancedMessage(
            content: "Test",
            isFromUser: true,
            timestamp: Date()
        )

        let url = try await SimplePDFGenerator.generatePDF(
            messages: [message],
            conversationTitle: "My/Test",
            modelName: nil
        )

        let filename = url.lastPathComponent
        XCTAssertTrue(filename.contains("My_Test"),
                      "Filename should include sanitized title, got: \(filename)")
        XCTAssertTrue(filename.hasPrefix("SAM_"), "Filename should start with SAM_, got: \(filename)")
        XCTAssertTrue(filename.hasSuffix(".pdf"), "Filename should end with .pdf, got: \(filename)")

        try? FileManager.default.removeItem(at: url)
    }
}
