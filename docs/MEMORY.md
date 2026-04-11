# SAM Memory System

**How SAM remembers, searches, and manages context**

---

## Overview

SAM has a multi-layered memory system that lets it remember information within conversations, search across conversations, import and analyze documents, and share context between conversations through Shared Topics. All memory is stored locally on your Mac.

---

## How Memory Works

### The Big Picture

```
You ask a question
    │
    ▼
SAM checks memory for relevant context
    │
    ├── Current conversation history
    ├── Imported document content (Vector RAG)
    ├── Stored memories from research
    └── Shared Topic entries (if applicable)
    │
    ▼
Relevant context is included with your question
    │
    ▼
AI responds with full awareness of context
```

This happens automatically. You don't need to tell SAM to "remember" something or "search your documents." It does it as part of normal conversation.

---

## Conversation Memory

### Within a Conversation

SAM maintains full history of every message in a conversation. The AI can reference anything you've discussed. As conversations get long, SAM uses intelligent context management to keep the most relevant information available.

### Context Window Management

Every AI model has a limit on how much text it can process at once (the "context window"). SAM manages this automatically:

1. **Recent messages** are always included
2. **Older messages** are compressed or summarized to save space
3. **Important messages** (those with key decisions, tool results, etc.) are prioritized
4. **System prompts and tool definitions** take a fixed portion of the window

SAM manages context by archiving older messages to a per-conversation SQLite database when the context window fills. Archived chunks include summaries, key topics, and timestamps, and are automatically retrieved via semantic search when relevant. Pinned messages are always preserved in context. Context window sizes vary by model.

---

## Semantic Search

### What is Semantic Search?

Traditional search matches exact words. Semantic search matches meaning. If you discussed "vacation planning" in an earlier conversation, searching for "trip itinerary" or "travel schedule" will find it - even though those exact words were never used.

### How It Works

SAM uses Apple's NaturalLanguage framework to create vector embeddings - mathematical representations of meaning - for text:

1. **Text chunking** - Content is split into meaningful segments
2. **Embedding generation** - Each segment gets a vector embedding computed on-device
3. **Storage** - Embeddings are stored in SQLite alongside the original text
4. **Query matching** - Your search query is embedded and compared against stored vectors
5. **Ranking** - Results are ranked by similarity score

All of this runs locally on your Mac using Apple's built-in NLP capabilities. No data is sent to any external service.

### Searching Across Conversations

Use the search feature (F) to search across all conversations. This searches:
- Message content
- Imported document content
- Stored research and memories

Results are ranked by semantic relevance and grouped by conversation.

---

## Vector RAG (Document Intelligence)

### What is Vector RAG?

RAG stands for Retrieval-Augmented Generation. When you import a document into SAM, it's processed into searchable chunks that the AI can reference when answering your questions. This means the AI doesn't need the entire document in its context window - it finds and uses the most relevant sections.

### How Document Import Works

1. **Import** - Drop a file into the conversation or use the import tool
2. **Text extraction** - SAM extracts text from the document (PDF, DOCX, XLSX, TXT)
3. **Chunking** - Text is split into overlapping segments for search accuracy
4. **Embedding** - Each chunk gets a vector embedding
5. **Storage** - Chunks and embeddings are stored in a per-conversation database

### Asking Questions About Documents

Once imported, just ask naturally:

- "What does the report say about Q4 revenue?"
- "Summarize the key findings"
- "Find the section about project timelines"
- "Compare the figures in table 2 and table 5"

SAM automatically:
1. Embeds your question
2. Finds the most relevant document chunks (using similarity thresholds)
3. Includes those chunks in the AI's context
4. The AI answers based on the actual document content

### Similarity Thresholds

SAM uses different similarity thresholds depending on the search type:

| Search Type | Threshold | Why |
|------------|-----------|-----|
| Document/RAG search | 0.15-0.25 | Broader matching for document retrieval |
| Conversation search | 0.3-0.5 | Tighter matching for specific recall |

If initial results are sparse, SAM automatically lowers the threshold incrementally to find more matches.

### Supported Document Formats

| Format | Extension | Extraction Method |
|--------|-----------|------------------|
| **PDF** | .pdf | Text extraction with layout awareness |
| **Word** | .docx | XML-based text extraction |
| **Excel** | .xlsx | Cell data extraction |
| **Text** | .txt, .md, .csv | Direct text processing |

---

## Stored Memories

### What Are Stored Memories?

When SAM conducts web research or you explicitly ask it to remember something, it stores the information in conversation memory. These stored memories are searchable and can be recalled later.

### How Research Memory Works

When SAM uses the `research` web tool:
1. It searches multiple sources
2. Synthesizes findings
3. Stores the synthesized results in memory
4. You can later ask "what did you find about X?" and SAM retrieves it

### Memory Operations

The AI has these memory tools:

| Operation | What It Does |
|-----------|-------------|
| `search_memory` | Find stored memories by semantic search |
| `store_memory` | Save information for later recall |
| `list_collections` | See what memory collections exist |
| `recall_history` | Recall conversation history by topic |

---

## Shared Topics

### What Are Shared Topics?

Shared Topics are named workspaces that connect multiple conversations around a common project or subject. All conversations assigned to a Shared Topic can access the same data.

### What Gets Shared

- **Working directory** - `~/SAM/{topic-name}/` instead of per-conversation directories
- **Topic entries** - Structured data that any conversation can read/write
- **File access** - All conversations see the same files

### What Stays Separate

- **Conversation history** - Each conversation keeps its own messages
- **Document imports** - Documents imported in one conversation stay in that conversation's Vector RAG

### Creating and Using Shared Topics

1. Start a new conversation
2. Assign it to a Shared Topic (create one if needed)
3. Work normally - SAM uses the shared workspace
4. Start another conversation and assign it to the same topic
5. Both conversations can access the shared files and entries

### Use Cases

- **Project management** - Keep all project discussions connected
- **Research** - Multiple research angles sharing a common knowledge base
- **Writing** - Draft, review, and revise documents across conversations
- **Team collaboration** - Multiple conversations contributing to the same output

### Technical Details

Shared Topics are backed by SQLite:
- **Topics table** - Name, description, owner, ACL
- **Entries table** - Key-value pairs within a topic
- **Lock management** - Optimistic locking prevents conflicts
- **Audit trail** - All operations are logged with timestamps

---

## Context Archive

### What Is Context Archiving?

For very long conversations, SAM can archive older context to free up the active context window. Archived context is still searchable but doesn't consume active tokens.

### How It Works

The ContextArchiveManager monitors conversation length and can:
- Compress older messages into summaries
- Archive detailed content while keeping summaries active
- Restore archived context when relevant to current discussion
- Maintain important messages (tool results, key decisions) longer than casual messages

---

## Data Storage

### Where Is Memory Stored?

```
~/Library/Application Support/SAM/
├── memory.db                     # Shared/global memory database
└── conversations/
    └── {UUID}/
        ├── conversation.json     # Messages and metadata
        ├── tasks.json            # Agent todo lists
        └── memory.db             # Per-conversation memory and vector embeddings
```

### Storage Size

- **Conversation JSON** - Grows with conversation length (typically 10KB-1MB)
- **Vector database** - Grows with imported documents (typically 1-50MB per conversation)
- **Total** - Depends on usage, typically 50MB-500MB for active users

### Cleanup

- Delete a conversation to remove all its data (messages, vectors, tasks)
- Conversations are not automatically deleted
- No remote sync or cloud backup

---

## Tips for Getting the Most from Memory

1. **Import full documents** instead of pasting excerpts - SAM can search the full content more effectively
2. **Use Shared Topics** for ongoing projects - keeps context connected across conversations
3. **Let SAM research** instead of pasting URLs - the research tool stores results in searchable memory
4. **Ask follow-up questions** - SAM uses conversation history, so building on previous messages works naturally
5. **Start new conversations** for new topics - keeps memory focused and relevant

---

## See Also

- [User Guide](USER_GUIDE.md) - Getting started with SAM
- [Features](FEATURES.md) - Complete feature reference
- [project-docs/MEMORY_AND_INTELLIGENCE_SPECIFICATION.md](../project-docs/MEMORY_AND_INTELLIGENCE_SPECIFICATION.md) - Technical implementation details
- [project-docs/CONVERSATION_ENGINE.md](../project-docs/CONVERSATION_ENGINE.md) - Conversation system internals
- [project-docs/SHARED_DATA.md](../project-docs/SHARED_DATA.md) - Shared Topics implementation
