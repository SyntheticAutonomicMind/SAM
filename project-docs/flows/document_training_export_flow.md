<!--
SPDX-License-Identifier: CC-BY-NC-4.0
SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)
-->

# Document Training Export Flow

**Last Updated:** January 11, 2026  
**License:** CC-BY-NC-4.0

## Overview

The Document Training Export Flow describes how documents and conversation memories are converted into JSONL training data for LoRA fine-tuning. This enables users to train models on specific content (PDFs, codebases, documentation) without manual conversation creation.

## Architecture Components

### Core Components

1. **DocumentImportSystem** - Imports documents (PDF, DOCX, code files)
2. **VectorRAGService** - Chunks and stores documents in memory
3. **MemoryManager** - SQLite storage for conversation-scoped memories
4. **DocumentChunker** - Splits documents using various strategies
5. **TrainingDataExporter** - Converts chunks to JSONL format
6. **PIIDetector** - Redacts sensitive information
7. **ChatTemplateEngine** - Formats output for specific models

### Data Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                    DOCUMENT IMPORT FLOW                         │
└─────────────────────────────────────────────────────────────────┘

User Selects Documents
        │
        ▼
   ┌─────────────────┐
   │ PDF/DOCX/Code   │
   │   Files         │
   └────────┬────────┘
            │
            ▼
   ┌─────────────────────────┐
   │ DocumentImportSystem    │
   │ - Extract text          │
   │ - OCR if needed         │
   │ - Get metadata          │
   └────────┬────────────────┘
            │
            ▼
   ┌─────────────────────────┐
   │ VectorRAGService        │
   │ - Chunk by pages/para   │
   │ - Generate embeddings   │
   └────────┬────────────────┘
            │
            ▼
   ┌─────────────────────────┐
   │ MemoryManager           │
   │ - Store chunks          │
   │ - Tag: "rag","document" │
   │ - Conversation-scoped   │
   └─────────────────────────┘


┌─────────────────────────────────────────────────────────────────┐
│              TRAINING DATA EXPORT FLOW (OPTION 1)               │
│                  Direct Document Export                         │
└─────────────────────────────────────────────────────────────────┘

ImportedDocument[]
        │
        ▼
   ┌─────────────────────────┐
   │ DocumentChunker         │
   │ Strategy:               │
   │ - Semantic (paragraphs) │
   │ - Fixed-size (tokens)   │
   │ - Page-aware (PDF)      │
   └────────┬────────────────┘
            │
            ▼
   ┌─────────────────────────┐
   │ DocumentChunk[]         │
   │ - text                  │
   │ - sourceFile            │
   │ - chunkIndex            │
   │ - pageNumber (opt)      │
   │ - metadata              │
   └────────┬────────────────┘
            │
            ▼
   ┌─────────────────────────┐
   │ PIIDetector (optional)  │
   │ - Redact email, phone   │
   │ - Redact SSN, names     │
   └────────┬────────────────┘
            │
            ▼
   ┌─────────────────────────┐
   │ ChatTemplateEngine      │
   │ - Format for model      │
   │ - Llama3/Qwen/etc       │
   └────────┬────────────────┘
            │
            ▼
   ┌─────────────────────────┐
   │ JSONL Output            │
   │ {"text":"...",          │
   │  "metadata":{...}}      │
   └─────────────────────────┘


┌─────────────────────────────────────────────────────────────────┐
│              TRAINING DATA EXPORT FLOW (OPTION 2)               │
│            Conversation Memory Export                           │
└─────────────────────────────────────────────────────────────────┘

ConversationID
        │
        ▼
   ┌─────────────────────────┐
   │ MemoryManager           │
   │ .getAllMemories(id)     │
   └────────┬────────────────┘
            │
            ▼
   ┌─────────────────────────┐
   │ Filter Document Chunks  │
   │ tags.contains("rag")    │
   │    OR                   │
   │ tags.contains("document")│
   └────────┬────────────────┘
            │
            ▼
   ┌─────────────────────────┐
   │ ConversationMemory[]    │
   │ - content (chunk text)  │
   │ - contentType           │
   │ - importance            │
   │ - tags                  │
   └────────┬────────────────┘
            │
            ▼
   ┌─────────────────────────┐
   │ Convert to Snapshot     │
   │ (avoid circular dep)    │
   └────────┬────────────────┘
            │
            ▼
   ┌─────────────────────────┐
   │ ConversationMemory      │
   │ Snapshot[]              │
   └────────┬────────────────┘
            │
            ▼
   ┌─────────────────────────┐
   │ PIIDetector (optional)  │
   │ - Redact sensitive data │
   └────────┬────────────────┘
            │
            ▼
   ┌─────────────────────────┐
   │ ChatTemplateEngine      │
   │ - Format for model      │
   └────────┬────────────────┘
            │
            ▼
   ┌─────────────────────────┐
   │ JSONL Output            │
   │ {"text":"...",          │
   │  "metadata":{...}}      │
   └─────────────────────────┘
```

## Flow 1: Direct Document Export

### Step 1: Document Import

**Trigger:** User selects files in DocumentImportSystem

**Processing:**
1. DocumentImportSystem validates file types (PDF, DOCX, code, text)
2. Appropriate processor extracts text:
   - PDFProcessor: Extract text + OCR fallback
   - OfficeProcessor: Parse DOCX/XLSX
   - TextProcessor: Read plain text/code files
3. Returns `ImportedDocument` with:
   - Extracted text content
   - Metadata (title, author, page count)
   - File information (name, size, type)

**Output:** `ImportedDocument[]`

### Step 2: Chunking

**Trigger:** Call `TrainingDataExporter.exportDocuments()`

**Processing:**
1. DocumentChunker selects strategy based on options:
   - **Semantic:** Split by double newlines (paragraphs)
   - **Fixed-size:** Split by token count with overlap
   - **Page-aware:** Split by PDF page boundaries
2. Chunks are created with:
   - Text content
   - Source file reference
   - Chunk index (sequential)
   - Page number (if page-aware)
   - Metadata from chunking strategy

**Example Semantic Chunking:**
```swift
// Input: Large document
"This is paragraph 1.\n\nThis is paragraph 2.\n\nThis is paragraph 3."

// Strategy: maxChunkTokens = 50
// Output: Multiple chunks
Chunk 0: "This is paragraph 1.\n\nThis is paragraph 2."
Chunk 1: "This is paragraph 3."
```

**Output:** `DocumentChunk[]`

### Step 3: PII Redaction (Optional)

**Trigger:** `options.stripPII = true`

**Processing:**
1. PIIDetector scans each chunk for:
   - Email addresses → `[REDACTED_EMAIL]`
   - Phone numbers → `[REDACTED_PHONE]`
   - SSNs → `[REDACTED_SSN]`
   - Names (NLTagger) → `[REDACTED_NAME]`
   - Locations → `[REDACTED_LOCATION]`
2. Builds redaction statistics
3. Returns cleaned chunks

**Output:** Cleaned `DocumentChunk[]` + redaction counts

### Step 4: Template Formatting

**Trigger:** Automatic (part of export)

**Processing:**
1. ChatTemplateEngine formats each chunk
2. Template selection (Llama3, Qwen, Mistral, etc.)
3. For text continuation (default):
   - Simple format without user/assistant markers
   - Just the chunk text
4. For conversation format (future):
   - Wrap in proper chat template

**Output:** Formatted strings

### Step 5: JSONL Writing

**Trigger:** Automatic (final step)

**Processing:**
1. Create JSONLEntry for each chunk:
   ```json
   {
     "text": "formatted chunk text",
     "metadata": {
       "sourceFile": "document.pdf",
       "chunkIndex": "0",
       "chunkType": "semantic",
       "pageNumber": "1"
     }
   }
   ```
2. Encode to JSON (one line per entry)
3. Write all lines to output file
4. Collect statistics (token count, file size)

**Output:** JSONL file + ExportStatistics

## Flow 2: Conversation Memory Export

### Step 1: Retrieve Memories

**Trigger:** User requests memory export for conversation

**Processing:**
1. Call `MemoryManager.getAllMemories(for: conversationId)`
2. Returns all memories for conversation:
   - Document chunks (tagged "rag", "document")
   - User inputs, assistant responses
   - Tool results, context info
3. Filter to keep only document memories:
   ```swift
   memories.filter { memory in
       memory.tags.contains("rag") || memory.tags.contains("document")
   }
   ```

**Output:** Filtered `ConversationMemory[]`

### Step 2: Convert to Snapshot

**Trigger:** Before calling exportConversationMemory()

**Purpose:** Avoid circular dependency between Training and ConversationEngine modules

**Processing:**
1. Map ConversationMemory → ConversationMemorySnapshot:
   ```swift
   memories.map { memory in
       ConversationMemorySnapshot(
           id: memory.id,
           content: memory.content,  // The chunk text
           contentType: memory.contentType.rawValue,
           importance: memory.importance,
           tags: memory.tags
       )
   }
   ```

**Output:** `ConversationMemorySnapshot[]`

### Step 3: Memory to Chunks

**Trigger:** Inside exportConversationMemory()

**Processing:**
1. Convert snapshots to DocumentChunk format:
   - Extract source file from tags (non-standard tags)
   - Use memory content as chunk text
   - Include memory metadata (ID, contentType, importance)
2. NO re-chunking happens (preserves original VectorRAG boundaries)

**Output:** `DocumentChunk[]`

### Step 4-6: Same as Flow 1

PII redaction, template formatting, and JSONL writing proceed identically to Flow 1.

## Chunking Strategies

### Semantic Chunking

**Best for:** Documents with clear structure (articles, documentation)

**Algorithm:**
1. Split text by double newlines (`\n\n`)
2. Trim whitespace from each paragraph
3. Combine paragraphs until token limit reached
4. Create chunk, start new accumulator
5. Repeat

**Advantages:**
- Preserves paragraph boundaries
- Maintains semantic meaning
- Good for well-structured documents

**Disadvantages:**
- Variable chunk sizes
- May create very small chunks if paragraphs are short

**Example:**
```
Input Document:
"Introduction paragraph 1.\n\nIntroduction paragraph 2.\n\nSection 1 content.\n\nSection 2 content."

With maxChunkTokens=100:
Chunk 0: "Introduction paragraph 1.\n\nIntroduction paragraph 2."
Chunk 1: "Section 1 content.\n\nSection 2 content."
```

### Fixed-Size Chunking

**Best for:** Continuous text without clear structure

**Algorithm:**
1. Split text into words
2. Build chunks by adding words until token limit
3. Create overlap by including last N tokens in next chunk
4. Continue until all words processed

**Advantages:**
- Consistent chunk sizes
- Overlap ensures no information loss at boundaries
- Works for any text

**Disadvantages:**
- May split mid-sentence or mid-concept
- Can break semantic units

**Example:**
```
Input: 200 words
maxChunkTokens=100, overlapTokens=10

Chunk 0: words 0-76 (≈100 tokens)
Chunk 1: words 67-143 (10 word overlap, ≈100 tokens)
Chunk 2: words 134-200 (10 word overlap, ≈87 tokens)
```

### Page-Aware Chunking

**Best for:** PDFs with distinct page structure

**Algorithm:**
1. Receive page boundaries from PDF processor
2. Combine pages until token limit reached
3. Preserve page numbers in metadata
4. Create chunks respecting page boundaries

**Advantages:**
- Maintains document structure
- Page numbers in metadata
- Good for books, papers, manuals

**Disadvantages:**
- Only works with documents that have page info
- Falls back to semantic chunking if no pages

**Example:**
```
Input PDF: 10 pages
maxChunkTokens=1000

Chunk 0: Pages 1-2 (pages="1,2")
Chunk 1: Pages 3-4 (pages="3,4")
Chunk 2: Pages 5-6 (pages="5,6")
...
```

## JSONL Output Format

### Basic Entry

```json
{"text":"This is the training text content.","metadata":{"sourceFile":"document.pdf","chunkIndex":"0","chunkType":"semantic"}}
```

### With Page Information

```json
{"text":"Chapter 1 content...","metadata":{"sourceFile":"book.pdf","chunkIndex":"0","pageNumber":"1","pages":"1,2","chunkType":"pageAware"}}
```

### With Memory Metadata

```json
{"text":"Imported document chunk...","metadata":{"memoryId":"550e8400-e29b-41d4-a716-446655440000","contentType":"document","importance":"0.8","tags":"rag,document,pdf"}}
```

## Error Handling

### Document Import Errors

**Unsupported File Type:**
- Error: `DocumentImportError.unsupportedFormat`
- Message: "Unknown content type for: filename.xyz"
- Recovery: Skip file, continue with others

**Access Denied:**
- Error: `DocumentImportError.accessDenied`
- Message: "Cannot access file: filename.pdf"
- Recovery: Check file permissions, try again

**Processing Failed:**
- Error: `DocumentImportError.processingFailed`
- Message: "Could not extract text from PDF"
- Recovery: Try OCR fallback (for PDFs)

### Export Errors

**No Document Data:**
- Error: `TrainingExportError.noConversationData`
- Condition: No document memories found in conversation
- Recovery: Import documents first

**Encoding Failed:**
- Error: `TrainingExportError.encodingFailed`
- Condition: Cannot encode JSONL
- Recovery: Check chunk content for invalid characters

**Invalid Output Path:**
- Error: `TrainingExportError.invalidOutputPath`
- Condition: Cannot write to output location
- Recovery: Check directory permissions

## Integration with LoRA Training

### Training Flow

```
JSONL Export → LoRA Training UI → Configure Parameters → Train → Test Adapter
```

**Steps:**

1. **Export:** Generate JSONL file using exportDocuments() or exportConversationMemory()
2. **Load:** Select JSONL file in LoRA training UI
3. **Configure:**
   - Epochs (default: 3)
   - Learning rate (default: 1e-5)
   - LoRA rank (default: 8)
   - LoRA alpha (default: 16)
4. **Train:** MLXTrainingService processes JSONL
5. **Save:** Adapter saved to `~/.sam/models/lora/`
6. **Test:** Load adapter and verify quality

### JSONL Compatibility

The exported JSONL format is compatible with:
- ✅ SAM's LoRA training (MLXTrainingService)
- ✅ Standard MLX training scripts
- ✅ HuggingFace Transformers (with minor adjustments)
- ✅ Axolotl training framework
- ✅ OpenAI fine-tuning API

## Performance Considerations

### Document Import

- **PDF Processing:** 1-5 seconds per page (with OCR: 10-30 seconds/page)
- **DOCX Processing:** < 1 second for most documents
- **Code Files:** Near-instant (simple text reading)
- **Bottleneck:** Vector embedding generation (0.1-0.5 sec/chunk)

### Training Export

- **Chunking:** Fast (< 1 second for 10,000 words)
- **PII Detection:** Moderate (1-2 seconds per 1000 words)
- **Template Formatting:** Fast (< 0.1 second per chunk)
- **JSONL Writing:** Fast (disk I/O bound)

**Typical Export Times:**
- 10-page PDF → JSONL: 2-5 seconds
- 100 code files → JSONL: 10-30 seconds
- Conversation memory (500 chunks) → JSONL: 3-8 seconds

## Use Cases

### 1. Train on Company Documentation

**Scenario:** Company has internal docs (benefits, policies)

**Workflow:**
1. Import all PDF/DOCX files
2. Export to JSONL with PII redaction enabled
3. Train LoRA adapter
4. Deploy adapter for employee queries

**Result:** Model understands company-specific terminology and policies

### 2. Train on Codebase

**Scenario:** Developer wants model that understands their project

**Workflow:**
1. Import all source files (.swift, .py, .js)
2. Use semantic chunking to preserve function boundaries
3. Export to JSONL
4. Train LoRA adapter
5. Use for code completion and explanation

**Result:** Model generates code in project style, understands architecture

### 3. Train on Research Papers

**Scenario:** Researcher wants model familiar with domain literature

**Workflow:**
1. Fetch papers from arXiv using web_operations
2. Import PDFs
3. Use page-aware chunking
4. Export to JSONL
5. Train LoRA adapter

**Result:** Model discusses research findings, knows methodology

### 4. Train on Conversation Memories

**Scenario:** User has imported documents into conversations over time

**Workflow:**
1. Retrieve all conversation memories
2. Filter for document chunks
3. Export directly (preserves original chunking)
4. Train LoRA adapter

**Result:** Model trained on accumulated knowledge base

## Comparison to Conversation Export

### Conversation Export (Existing)

- **Input:** EnhancedMessage[] (user/assistant pairs)
- **Output:** JSONL with user/assistant structure
- **Format:** Q&A pairs, conversation turns
- **Use case:** Training conversational behavior

### Document Export (New)

- **Input:** ImportedDocument[] OR ConversationMemorySnapshot[]
- **Output:** JSONL with text continuation format
- **Format:** Plain text chunks (no user/assistant)
- **Use case:** Training domain knowledge

### When to Use Which

| Scenario | Use | Reason |
|----------|-----|--------|
| Train conversation style | Conversation export | Preserves dialog structure |
| Train on facts/knowledge | Document export | Pure content learning |
| Train on code | Document export | Code chunks work better |
| Train on both | Combine both | Multi-task learning |

## Summary

The Document Training Export flow enables:

✅ Import documents from various sources (PDF, DOCX, code, web)  
✅ Chunk documents using optimal strategies  
✅ Export to JSONL format for LoRA training  
✅ Reuse conversation-scoped memories  
✅ Redact PII for privacy  
✅ Format for any model architecture  

This forms a complete pipeline from raw documents to trained LoRA adapters, enabling domain-specific fine-tuning without manual data preparation.
