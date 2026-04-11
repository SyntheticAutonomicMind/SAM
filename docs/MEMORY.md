# SAM Memory System

How SAM remembers, searches, archives, and reuses context.

---

## Overview

SAM uses several layers of memory rather than treating every conversation as a flat message log.

These layers include:
- active conversation history
- semantic search over prior content
- per-conversation working memory
- archived context recall
- long-term memory structures
- document-backed retrieval
- shared-topic context across related conversations

All of this is designed to stay local to your Mac unless you explicitly use a cloud provider for inference.

---

## Memory Layers

### 1. Active conversation context

The current conversation always provides the most immediate context for the model.

### 2. Semantic memory search

SAM can search prior conversation content and memory entries by meaning, not just literal text match.

### 3. Working key-value memory

SAM supports per-conversation working notes through key-value memory operations such as:
- `store`
- `retrieve`
- `search_kv`
- `list_keys`
- `delete_key`

This is useful for task state, reference values, and notes that need to survive across app restarts.

### 4. Archived context recall

When conversations get long, older context can be trimmed from the active window and later recalled with `recall_history`.

### 5. Long-term memory

SAM also supports longer-lived memory primitives such as:
- discoveries
- solutions
- patterns
- long-term memory stats and pruning

### 6. Shared-topic memory scope

When a conversation is attached to a Shared Topic, SAM can use topic-aware context retrieval so related conversations can benefit from prior work in the same project area.

---

## Semantic Search

Semantic search is used to find relevant material even when the exact wording differs.

That means SAM can often match:
- similar concepts
- related phrases
- earlier discussions using different wording

This applies to conversation memory and imported document content.

---

## Document-Backed Retrieval

When documents are imported into a conversation, SAM can process them into searchable content for later retrieval.

This supports question answering and contextual assistance without dumping the entire document into the active prompt every time.

### Common supported formats in the document workflow

- PDF
- DOCX
- XLSX
- TXT
- Markdown and other text-based content handled by the document pipeline

Document import and document creation are handled through the document tooling, while retrieval behavior ties into memory and context systems.

---

## Context Trimming and Recall

Large conversations eventually exceed the practical context window of a model. SAM handles that by trimming and archiving older context.

The important point is that trimming is not the same as forgetting.

With archived recall, SAM can:
- bring older relevant context back into play
- preserve project continuity across long sessions
- avoid wasting context window space on everything at once

---

## Long-Term Memory Operations

The long-term memory layer is built for capturing reusable knowledge.

### Discovery memory
Store facts worth preserving.

### Solution memory
Store problem/solution pairs that may matter again.

### Pattern memory
Store recurring practices or workflow patterns.

### Maintenance
Use stats and pruning operations to inspect or clean long-term memory state.

---

## Shared Topics and Shared Work

Shared Topics allow multiple conversations to work within a common project space while still maintaining separate message histories.

In practice, this gives SAM a way to support project-based continuity without turning every conversation into one giant transcript.

Shared Topics matter because they are more than just a folder name. In the current system they influence how relevant context can be discovered and injected across related conversations.

That makes them especially useful for:

- ongoing software projects
- multi-session research
- collaborative planning across several chats
- long-lived work where earlier decisions still matter

---

## Storage Model

SAM stores memory-related data under its local application data tree.

Typical locations include:

```text
~/Library/Application Support/SAM/
├── memory.db
└── conversations/
    └── {UUID}/
        ├── conversation.json
        ├── tasks.json
        └── memory.db
```

Working files for conversation and topic workflows live in:

```text
~/SAM/
```

Conversation exports and related artifacts can also be generated through SAM's export flows when you want to share or archive work outside the live conversation.

---

## Why This Matters

SAM's memory system is designed to support real ongoing work, not just single-turn chat.

That means it can help with:
- long-running projects
- recurring technical work
- research sessions
- document-assisted workflows
- persistent notes and learned patterns

---

## See Also

- [Tools](TOOLS.md)
- [Features](FEATURES.md)
- [Architecture](ARCHITECTURE.md)
- [Security](SECURITY.md)
