// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Chunks documents into training-sized pieces using various strategies
public actor DocumentChunker {
    private let logger = Logger(label: "com.sam.training.chunker")
    
    public init() {}
    
    /// Chunk a document's text into training examples
    /// - Parameters:
    ///   - text: The full text to chunk
    ///   - sourceFile: Name of the source file
    ///   - options: Chunking configuration
    ///   - pages: Optional page boundaries for page-aware chunking
    /// - Returns: Array of document chunks
    public func chunkDocument(
        text: String,
        sourceFile: String,
        options: TrainingDataModels.DocumentExportOptions,
        pages: [PageContent]? = nil
    ) -> [TrainingDataModels.DocumentChunk] {
        logger.debug("Chunking document", metadata: [
            "file": "\(sourceFile)",
            "strategy": "\(options.chunkingStrategy.rawValue)",
            "textLength": "\(text.count)"
        ])
        
        let chunks: [TrainingDataModels.DocumentChunk]
        
        switch options.chunkingStrategy {
        case .semantic:
            chunks = chunkBySemantic(text: text, sourceFile: sourceFile, options: options)
        case .fixedSize:
            chunks = chunkByFixedSize(text: text, sourceFile: sourceFile, options: options)
        case .pageAware:
            chunks = chunkByPages(text: text, sourceFile: sourceFile, pages: pages, options: options)
        }
        
        logger.debug("Chunking complete", metadata: [
            "chunks": "\(chunks.count)",
            "averageSize": "\(chunks.isEmpty ? 0 : chunks.map { $0.text.count }.reduce(0, +) / chunks.count)"
        ])
        
        return chunks
    }
    
    // MARK: - Chunking Strategies
    
    /// Semantic chunking by paragraphs and sections
    private func chunkBySemantic(
        text: String,
        sourceFile: String,
        options: TrainingDataModels.DocumentExportOptions
    ) -> [TrainingDataModels.DocumentChunk] {
        // Split by double newlines (paragraphs)
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        var chunks: [TrainingDataModels.DocumentChunk] = []
        var currentChunk = ""
        var chunkIndex = 0
        
        for paragraph in paragraphs {
            let potentialChunk = currentChunk.isEmpty ? paragraph : "\(currentChunk)\n\n\(paragraph)"
            let tokenEstimate = estimateTokens(for: potentialChunk)
            
            if tokenEstimate > options.maxChunkTokens && !currentChunk.isEmpty {
                // Current chunk is full, save it
                chunks.append(TrainingDataModels.DocumentChunk(
                    text: currentChunk,
                    sourceFile: sourceFile,
                    chunkIndex: chunkIndex,
                    metadata: [
                        "chunkType": "semantic",
                        "paragraphCount": "\(currentChunk.components(separatedBy: "\n\n").count)"
                    ]
                ))
                chunkIndex += 1
                currentChunk = paragraph
            } else {
                currentChunk = potentialChunk
            }
        }
        
        // Add final chunk
        if !currentChunk.isEmpty {
            chunks.append(TrainingDataModels.DocumentChunk(
                text: currentChunk,
                sourceFile: sourceFile,
                chunkIndex: chunkIndex,
                metadata: [
                    "chunkType": "semantic",
                    "paragraphCount": "\(currentChunk.components(separatedBy: "\n\n").count)"
                ]
            ))
        }
        
        return chunks
    }
    
    /// Fixed-size chunking with overlap
    private func chunkByFixedSize(
        text: String,
        sourceFile: String,
        options: TrainingDataModels.DocumentExportOptions
    ) -> [TrainingDataModels.DocumentChunk] {
        // Split into words to ensure we don't break mid-word
        let words = text.split(separator: " ").map { String($0) }
        
        var chunks: [TrainingDataModels.DocumentChunk] = []
        var chunkIndex = 0
        var startIndex = 0
        
        while startIndex < words.count {
            var endIndex = startIndex
            var currentText = ""
            
            // Build chunk up to max tokens
            while endIndex < words.count {
                let word = words[endIndex]
                let potentialText = currentText.isEmpty ? word : "\(currentText) \(word)"
                let tokenEstimate = estimateTokens(for: potentialText)
                
                if tokenEstimate > options.maxChunkTokens && !currentText.isEmpty {
                    break
                }
                
                currentText = potentialText
                endIndex += 1
            }
            
            if !currentText.isEmpty {
                chunks.append(TrainingDataModels.DocumentChunk(
                    text: currentText,
                    sourceFile: sourceFile,
                    chunkIndex: chunkIndex,
                    metadata: [
                        "chunkType": "fixedSize",
                        "wordCount": "\(currentText.split(separator: " ").count)"
                    ]
                ))
                chunkIndex += 1
            }
            
            // Calculate overlap for next chunk
            let overlapWords = min(options.overlapTokens, endIndex - startIndex)
            startIndex = max(startIndex + 1, endIndex - overlapWords)
            
            // Prevent infinite loop
            if startIndex >= words.count || currentText.isEmpty {
                break
            }
        }
        
        return chunks
    }
    
    /// Page-aware chunking (for PDFs with page boundaries)
    private func chunkByPages(
        text: String,
        sourceFile: String,
        pages: [PageContent]?,
        options: TrainingDataModels.DocumentExportOptions
    ) -> [TrainingDataModels.DocumentChunk] {
        guard let pages = pages, !pages.isEmpty else {
            // Fall back to semantic chunking if no page info
            logger.debug("No page information available, falling back to semantic chunking")
            return chunkBySemantic(text: text, sourceFile: sourceFile, options: options)
        }
        
        var chunks: [TrainingDataModels.DocumentChunk] = []
        var currentText = ""
        var currentPages: [Int] = []
        var chunkIndex = 0
        
        for page in pages {
            let potentialText = currentText.isEmpty ? page.text : "\(currentText)\n\n\(page.text)"
            let tokenEstimate = estimateTokens(for: potentialText)
            
            if tokenEstimate > options.maxChunkTokens && !currentText.isEmpty {
                // Current chunk is full, save it
                chunks.append(TrainingDataModels.DocumentChunk(
                    text: currentText,
                    sourceFile: sourceFile,
                    chunkIndex: chunkIndex,
                    pageNumber: currentPages.first,
                    metadata: [
                        "chunkType": "pageAware",
                        "pages": currentPages.map { String($0) }.joined(separator: ","),
                        "pageCount": "\(currentPages.count)"
                    ]
                ))
                chunkIndex += 1
                currentText = page.text
                currentPages = [page.pageNumber]
            } else {
                currentText = potentialText
                currentPages.append(page.pageNumber)
            }
        }
        
        // Add final chunk
        if !currentText.isEmpty {
            chunks.append(TrainingDataModels.DocumentChunk(
                text: currentText,
                sourceFile: sourceFile,
                chunkIndex: chunkIndex,
                pageNumber: currentPages.first,
                metadata: [
                    "chunkType": "pageAware",
                    "pages": currentPages.map { String($0) }.joined(separator: ","),
                    "pageCount": "\(currentPages.count)"
                ]
            ))
        }
        
        return chunks
    }
    
    // MARK: - Helper Methods
    
    /// Estimate token count for text (words * 1.3)
    private func estimateTokens(for text: String) -> Int {
        let words = text.split(separator: " ").count
        return Int(Double(words) * 1.3)
    }
}

/// Page content structure (matches DocumentProcessors.PageContent)
public struct PageContent: Sendable {
    public let pageNumber: Int
    public let text: String
    
    public init(pageNumber: Int, text: String) {
        self.pageNumber = pageNumber
        self.text = text
    }
}
