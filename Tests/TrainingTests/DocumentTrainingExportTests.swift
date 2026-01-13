// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import XCTest
@testable import Training

/// Tests for document-to-training-data export functionality
final class DocumentTrainingExportTests: XCTestCase {
    
    func testDocumentChunkerSemantic() async throws {
        let chunker = DocumentChunker()
        
        let testText = """
        This is the first paragraph. It contains some important information about machine learning.
        
        This is the second paragraph. It discusses neural networks and their applications.
        
        This is the third paragraph. It covers deep learning and training processes.
        """
        
        let options = TrainingDataModels.DocumentExportOptions(
            chunkingStrategy: .semantic,
            maxChunkTokens: 50
        )
        
        let chunks = await chunker.chunkDocument(
            text: testText,
            sourceFile: "test.txt",
            options: options
        )
        
        XCTAssertGreaterThan(chunks.count, 0, "Should create at least one chunk")
        XCTAssertEqual(chunks[0].sourceFile, "test.txt")
        XCTAssertEqual(chunks[0].chunkIndex, 0)
    }
    
    func testDocumentChunkerFixedSize() async throws {
        let chunker = DocumentChunker()
        
        let testText = String(repeating: "word ", count: 200)
        
        let options = TrainingDataModels.DocumentExportOptions(
            chunkingStrategy: .fixedSize,
            maxChunkTokens: 100,
            overlapTokens: 10
        )
        
        let chunks = await chunker.chunkDocument(
            text: testText,
            sourceFile: "test.txt",
            options: options
        )
        
        XCTAssertGreaterThan(chunks.count, 1, "Should create multiple chunks from large text")
        for chunk in chunks {
            XCTAssertFalse(chunk.text.isEmpty, "Chunks should not be empty")
        }
    }
    
    func testDocumentChunkerPageAware() async throws {
        let chunker = DocumentChunker()
        
        let pages = [
            PageContent(pageNumber: 1, text: "Page 1 content"),
            PageContent(pageNumber: 2, text: "Page 2 content"),
            PageContent(pageNumber: 3, text: "Page 3 content")
        ]
        
        let options = TrainingDataModels.DocumentExportOptions(
            chunkingStrategy: .pageAware,
            maxChunkTokens: 50
        )
        
        let chunks = await chunker.chunkDocument(
            text: "Combined text",
            sourceFile: "test.pdf",
            options: options,
            pages: pages
        )
        
        XCTAssertGreaterThan(chunks.count, 0, "Should create chunks from pages")
        XCTAssertNotNil(chunks[0].pageNumber, "Page-aware chunks should have page numbers")
    }
    
    func testExportDocuments() async throws {
        let exporter = TrainingDataExporter()
        
        let testDoc = ImportedDocument(
            id: UUID(),
            filename: "test.txt",
            content: "This is a test document.\n\nIt has multiple paragraphs.\n\nAnd should be chunked appropriately.",
            metadata: ["source": "test"]
        )
        
        let outputURL = URL(fileURLWithPath: "scratch/test_export.jsonl")
        
        let options = TrainingDataModels.DocumentExportOptions(
            chunkingStrategy: .semantic,
            maxChunkTokens: 100,
            template: .llama3
        )
        
        let result = try await exporter.exportDocuments(
            documents: [testDoc],
            outputURL: outputURL,
            options: options
        )
        
        XCTAssertEqual(result.outputURL, outputURL)
        XCTAssertGreaterThan(result.statistics.totalExamples, 0, "Should create at least one training example")
        XCTAssertGreaterThan(result.statistics.totalTokensEstimate, 0, "Should estimate token count")
        
        // Verify file was created
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path), "JSONL file should be created")
        
        // Clean up
        try? FileManager.default.removeItem(at: outputURL)
    }
    
    func testJSONLFormat() async throws {
        let exporter = TrainingDataExporter()
        
        let testDoc = ImportedDocument(
            id: UUID(),
            filename: "format_test.txt",
            content: "Short test content for format verification.",
            metadata: [:]
        )
        
        let outputURL = URL(fileURLWithPath: "scratch/format_test.jsonl")
        
        let options = TrainingDataModels.DocumentExportOptions(
            chunkingStrategy: .semantic,
            maxChunkTokens: 100
        )
        
        _ = try await exporter.exportDocuments(
            documents: [testDoc],
            outputURL: outputURL,
            options: options
        )
        
        // Read and verify JSONL format
        let content = try String(contentsOf: outputURL, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        
        XCTAssertGreaterThan(lines.count, 0, "Should have at least one line")
        
        // Verify each line is valid JSON
        for line in lines {
            let data = line.data(using: .utf8)!
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertNotNil(json, "Each line should be valid JSON")
            XCTAssertNotNil(json?["text"], "Each entry should have 'text' field")
            XCTAssertNotNil(json?["metadata"], "Each entry should have 'metadata' field")
        }
        
        // Clean up
        try? FileManager.default.removeItem(at: outputURL)
    }
}
