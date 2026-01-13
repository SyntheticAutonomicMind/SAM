<!--
SPDX-License-Identifier: CC-BY-NC-4.0
SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)
-->

# Document Training Export - Usage Guide

**Last Updated:** January 11, 2026  
**License:** CC-BY-NC-4.0

## Overview

The new document training export functionality allows you to convert imported documents directly into JSONL training data for LoRA fine-tuning, without needing to create conversations first.

## Architecture

### New Components

1. **DocumentChunker** (`Sources/Training/DocumentChunker.swift`)
   - Chunks documents using three strategies: semantic, fixed-size, page-aware
   - Handles text splitting with configurable overlap
   - Preserves context boundaries (paragraphs, pages, code blocks)

2. **DocumentExportOptions** (in `Sources/Training/TrainingDataModels.swift`)
   - Configuration for chunking strategy, max tokens, overlap
   - PII redaction settings
   - Chat template selection

3. **TrainingDataExporter.exportDocuments()** (in `Sources/Training/TrainingDataExporter.swift`)
   - New method alongside existing `exportConversation()`
   - Takes array of ImportedDocument objects
   - Returns JSONL file compatible with LoRA training

### Integration Points

The new functionality integrates with existing SAM components:

- **DocumentImportSystem**: Import PDFs, DOCX, code files → Get ImportedDocument objects
- **WebOperationsTool**: Fetch web content → Convert to ImportedDocument
- **TrainingDataExporter**: Export ImportedDocument → JSONL training data
- **LoRA Training**: Existing training flow accepts the JSONL output

## Usage Examples

### Example 1: Export Imported Documents

```swift
import Training
import UserInterface

// 1. Import documents using DocumentImportSystem
let importSystem = DocumentImportSystem(conversationManager: manager)
let documents = try await importSystem.importDocuments(
    from: [pdfURL, docxURL],
    conversationId: nil  // Global, not conversation-scoped
)

// 2. Create export options
let options = TrainingDataModels.DocumentExportOptions(
    chunkingStrategy: .semantic,  // Split by paragraphs
    maxChunkTokens: 512,           // Max chunk size
    overlapTokens: 50,             // Overlap between chunks
    stripPII: true,                // Redact sensitive info
    template: .llama3              // Chat template format
)

// 3. Export to JSONL
let exporter = TrainingDataExporter()
let result = try await exporter.exportDocuments(
    documents: documents.map { ImportedDocument(
        id: $0.id,
        filename: $0.filename,
        content: $0.content,
        metadata: $0.metadata
    )},
    outputURL: URL(fileURLWithPath: "training_data.jsonl"),
    options: options
)

print("Exported \(result.statistics.totalExamples) training examples")
print("Estimated tokens: \(result.statistics.totalTokensEstimate)")
```

### Example 2: Export Conversation Memory

```swift
import Training
import ConversationEngine

// 1. Get conversation memories
let memories = try await memoryManager.getAllMemories(for: conversationId)

// 2. Convert to snapshot format (avoids circular dependency)
let snapshots = memories.map { memory in
    TrainingDataModels.ConversationMemorySnapshot(
        id: memory.id,
        content: memory.content,
        contentType: memory.contentType.rawValue,
        importance: memory.importance,
        tags: memory.tags
    )
}

// 3. Export memory to training data
let options = TrainingDataModels.DocumentExportOptions(
    stripPII: true,
    template: .llama3
)

let result = try await exporter.exportConversationMemory(
    memories: snapshots,
    outputURL: URL(fileURLWithPath: "memory_training.jsonl"),
    options: options
)

print("Exported \(result.statistics.totalExamples) memory chunks")
```

### Example 3: Page-Aware PDF Export

```swift
// For PDFs with page boundaries
let options = TrainingDataModels.DocumentExportOptions(
    chunkingStrategy: .pageAware,  // Use page boundaries
    maxChunkTokens: 1024,
    template: .qwen
)

// Pass page information if available
let result = try await exporter.exportDocuments(
    documents: pdfDocuments,
    outputURL: outputURL,
    options: options,
    pages: [
        "document.pdf": [
            PageContent(pageNumber: 1, text: "Page 1 text..."),
            PageContent(pageNumber: 2, text: "Page 2 text...")
        ]
    ]
)
```

### Example 3: Page-Aware PDF Export

```swift
// For PDFs with page boundaries
let options = TrainingDataModels.DocumentExportOptions(
    chunkingStrategy: .pageAware,  // Use page boundaries
    maxChunkTokens: 1024,
    template: .qwen
)

// Pass page information if available
let result = try await exporter.exportDocuments(
    documents: pdfDocuments,
    outputURL: outputURL,
    options: options,
    pages: [
        "document.pdf": [
            PageContent(pageNumber: 1, text: "Page 1 text..."),
            PageContent(pageNumber: 2, text: "Page 2 text...")
        ]
    ]
)
```

### Example 4: Code Repository Export

```swift
// Import all Swift files from a directory
let codeFiles = try FileManager.default.contentsOfDirectory(at: sourcesURL, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "swift" }

let documents = try await importSystem.importDocuments(from: codeFiles)

// Use semantic chunking to preserve function/class boundaries
let options = TrainingDataModels.DocumentExportOptions(
    chunkingStrategy: .semantic,
    maxChunkTokens: 768,
    template: .custom,
    customTemplate: modelTemplate  // From installed model
)

let result = try await exporter.exportDocuments(
    documents: documents.map { /* convert to ImportedDocument */ },
    outputURL: URL(fileURLWithPath: "codebase_training.jsonl"),
    options: options
)
```

## Chunking Strategies

### Semantic Chunking (.semantic)

- **Best for**: Documents with clear paragraph structure, articles, documentation
- **How it works**: Splits on double newlines (paragraph boundaries)
- **Pros**: Preserves meaning, respects document structure
- **Cons**: Variable chunk sizes

### Fixed-Size Chunking (.fixedSize)

- **Best for**: Long documents without clear structure, continuous text
- **How it works**: Splits by word count with configurable overlap
- **Pros**: Consistent chunk sizes, good coverage with overlap
- **Cons**: May split mid-sentence or mid-concept

### Page-Aware Chunking (.pageAware)

- **Best for**: PDFs with distinct pages, books, academic papers
- **How it works**: Uses page boundaries from PDF metadata
- **Pros**: Preserves page context, metadata includes page numbers
- **Cons**: Only works with documents that have page information

## Output Format

The JSONL output matches the format used by conversation exports:

```json
{"text":"Machine learning is a subset of AI...","metadata":{"sourceFile":"ml_basics.txt","chunkIndex":"0","chunkType":"semantic"}}
{"text":"Supervised learning involves training...","metadata":{"sourceFile":"ml_basics.txt","chunkIndex":"1","chunkType":"semantic"}}
```

For page-aware chunks:

```json
{"text":"Chapter 1: Introduction...","metadata":{"sourceFile":"book.pdf","chunkIndex":"0","pageNumber":"1","pages":"1,2","chunkType":"pageAware"}}
```

## Integration with LoRA Training

The generated JSONL files work directly with SAM's existing LoRA training:

1. Export documents → `training_data.jsonl`
2. Use training UI to select the JSONL file
3. Configure training parameters (epochs, learning rate, rank, alpha)
4. Train LoRA adapter
5. Load adapter for inference

## PII Redaction

Document export supports the same PII detection as conversation export:

```swift
let options = TrainingDataModels.DocumentExportOptions(
    stripPII: true,
    selectedPIIEntities: [
        .personalName,
        .organizationName,
        .emailAddress,
        .phoneNumber,
        .socialSecurityNumber
    ]
)
```

Redacted entities are replaced with `[REDACTED_EMAIL]`, etc.

## Testing

Create test documents:

```bash
# Create sample document
cat > scratch/test_doc.txt << 'EOF'
# Introduction

This is a test document with multiple paragraphs.

## Section 1

Some content here.

## Section 2

More content here.
EOF

# The document can be imported and exported using the Swift API
```

Verify JSONL format:

```bash
# Each line should be valid JSON
cat training_data.jsonl | head -n 3 | python3 -m json.tool
```

## Limitations and Future Enhancements

**Current MVP limitations:**

- No Q&A pair generation (only text continuation format)
- No automatic quality filtering
- No synthetic question generation
- No bulk directory import UI
- No web content integration (requires manual fetch first)

**Planned enhancements:**

1. Q&A pair generation from chunks (use LLM to generate questions)
2. Bulk import UI for directories
3. Web content pipeline (URL → fetch → import → export)
4. Quality scoring and filtering
5. Code-aware chunking (preserve complete functions/classes)
6. Multi-document aggregation with deduplication

## Architecture Decisions

### Why extend TrainingDataExporter?

- Reuses existing JSONL writing, PII detection, template formatting
- Keeps all export logic in one place
- Consistent output format with conversation exports
- Easy to maintain and test

### Why separate DocumentChunker?

- Single responsibility (chunking vs. export)
- Reusable for other purposes
- Easier to test chunking strategies independently
- Can swap strategies without changing export logic

### Why three chunking strategies?

- Different document types need different approaches
- Users can choose based on their use case
- Future-proof for additional strategies

## Summary

The document training export feature enables:

✅ Direct path from documents to training data  
✅ Multiple chunking strategies for different content types  
✅ PII redaction for sensitive documents  
✅ Compatible with existing LoRA training flow  
✅ Reuses proven SAM components  
✅ Clean, maintainable architecture  

This forms the foundation for more advanced features like Q&A generation, web content pipelines, and codebase training.
