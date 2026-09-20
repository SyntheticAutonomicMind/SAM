<!-- SPDX-License-Identifier: CC-BY-NC-4.0 -->
<!-- SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius) -->


# MCPFramework Subsystem Documentation

**Version:** 2.0  
**Last Updated:** August 23, 2026  
**Module:** `Sources/MCPFramework/`

---

## Overview

The **MCPFramework** is SAM's tool execution system, implementing a consolidated tool architecture where related operations are grouped under unified tools with an `operation` parameter. Internal sub-tools handle individual operations but are not directly visible to the LLM.

**Tool Count:** 12 consolidated tools exposed to the LLM  
**Internal Tools:** ~80 sub-operations dispatched by consolidated tools

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      MCPManager                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              UniversalToolRegistry                   │    │
│  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐    │    │
│  │  │ Tool 1      │ │ Tool 2      │ │ Tool N      │    │    │
│  │  │ (Consolidated)│ │ (Consolidated)│ │ (Consolidated)│    │    │
│  │  └──────┬──────┘ └──────┬──────┘ └──────┬──────┘    │    │
│  └─────────┼───────────────┼───────────────┼────────────┘    │
│            │               │               │                 │
│      ┌─────┴─────┐    ┌────┴────┐    ┌────┴────┐           │
│      │ Sub-tool  │    │Sub-tool │    │Sub-tool │           │
│      │ 1..N      │    │ 1..N    │    │ 1..N    │           │
│      └───────────┘    └─────────┘    └─────────┘           │
└─────────────────────────────────────────────────────────────┘
```

### Key Components

| Component | Location | Responsibility |
|-----------|----------|----------------|
| **MCPManager** | `MCPManager.swift` | Central coordinator, tool registration, execution |
| **UniversalToolRegistry** | `ToolRegistry.swift` | Tool registration, lookup, KV cache ordering |
| **MCPTool Protocol** | `MCPTool.swift` | Base protocol all tools implement |
| **ConsolidatedMCP** | `MCPTool.swift` | Base class for consolidated tools |
| **ToolRegistry** | `ToolRegistry.swift` | Legacy registry (being phased out) |
| **ToolResult** | `ToolResult.swift` | Standardized result format |
| **Authorization** | `Authorization/` | Path-based authorization checks |
| **Tools/** | `Tools/` | 12 consolidated tool implementations |

---

## Tool Registry (Ordered for KV Cache Consistency)

Tools are registered in a fixed order to maintain KV cache stability across requests:

| # | Tool Name | Purpose |
|---|-----------|---------|
| 1 | `user_collaboration` | Pause for user input mid-execution |
| 2 | `todo_operations` | Agent task tracking for multi-step work |
| 3 | `memory_operations` | Search/store conversation memories, LTM, KV store |
| 4 | `web_operations` | Web search, research, scraping, fetching |
| 5 | `document_operations` | Import/create PDF, DOCX, PPTX, XLSX, MD, RTF |
| 6 | `file_operations` | Read, search, write, manage files |
| 7 | `math_operations` | Mathematical calculations, formulas, unit conversions |
| 8 | `calendar_operations` | Calendar and reminder management (EventKit) |
| 9 | `contacts_operations` | Contacts framework integration |
| 10 | `notes_operations` | Apple Notes integration |
| 11 | `spotlight_search` | macOS Spotlight file/metadata search |
| 12 | `weather_operations` | Weather via Open-Meteo |
| 13 | `image_generation` | Image generation via remote ALICE server (conditional) |

---

## Authorization Model

**Path-based authorization:**
- Inside working directory (`~/SAM/`): Auto-approved
- Outside working directory: Requires `user_collaboration` confirmation
- Relative paths: Auto-resolve to working directory

**Working Directories:**
- Per-conversation: `~/SAM/conversation-{number}/`
- Shared topics: `~/SAM/{topic-name}/`

**Tool Privacy Controls:**
- Calendar/Contacts/Notes require macOS permission prompts
- Spotlight uses system index, respects macOS privacy settings
- File operations enforce working directory boundaries

---

## Tool Specifications

### user_collaboration

**Pause for user input mid-execution**

**Operations:** `request_input`

**Use for:**
- Ambiguous requests needing clarification
- Multiple valid approaches - let user choose
- Confirmation before destructive operations
- Information only user knows

**Don't use for:**
- Questions answerable with other tools
- Information already in conversation context

---

### todo_operations

**Agent task tracking for multi-step work (NOT user todo lists)**

**Operations:** `read`, `write`, `update`, `add`

**Workflow:**
1. Create todo list for complex requests
2. Mark ONE todo in-progress before starting
3. Complete work on that specific todo
4. Mark completed immediately
4. Move to next todo

**Enforcement:** Orchestrator injects workflow guidance when todos exist

---

### memory_operations

**Search and store conversation memories, LTM, and KV store**

**Session Memory Operations:**
- `search_memory` - Semantic search across conversation memories
- `store_memory` - Save information for later recall
- `list_collections` - List available memory collections
- `recall_history` - Recall conversation history by topic

**Key-Value Working Memory:**
- `store` - Store key-value pair (key, content)
- `retrieve` - Get stored value by key
- `search_kv` - Search key-value store
- `list_keys` - List all stored keys
- `delete_key` - Delete a key from the store

**Long-Term Memory Operations:**
- `add_discovery` - Add a discovery to LTM
- `add_solution` - Add a solution to LTM
- `add_pattern` - Add a pattern to LTM
- `ltm_stats` - Show LTM statistics
- `prune_ltm` - Prune old LTM entries

**Similarity Thresholds:**
- Document/RAG: 0.15-0.25
- Conversation: 0.3-0.5
- No results: Lower incrementally

---

### web_operations

**Operations:** `research`, `retrieve`, `web_search`, `serpapi`, `scrape`, `fetch`

- **research:** Comprehensive multi-source research + memory storage
- **retrieve:** Access stored research from memory
- **web_search:** Search web (Google, Bing, DuckDuckGo)
- **serpapi:** Direct SerpAPI access (Google, Bing, Amazon, eBay, TripAdvisor, Walmart, Yelp)
- **scrape:** WebKit with JS support (slower, complete)
- **fetch:** Basic HTTP, no JS (faster)

---

### document_operations

**Operations:** `document_import`, `document_create`, `get_doc_info`

- **Import formats:** PDF, DOCX, XLSX, TXT, MD, CSV
- **Create formats:** PDF, DOCX, PPTX, TXT, MD, RTF, XLSX

---

### file_operations

**Dispatches to internal tools for:**

**Read operations:**
- `read_file` - Read file content with optional line range
- `list_dir` - List directory contents (recursive or flat)
- `get_file_info` - Get file metadata (size, type, modified time)
- `get_errors` - Check a file for compilation/lint errors

**Search operations:**
- `file_search` - Find files matching a glob pattern
- `grep_search` - Search file contents with text or regex
- `semantic_search` - Find files by meaning using NLP
- `list_usages` - Find all references to a symbol

**Write operations:**
- `create_file` - Create a new file with content
- `write_file` - Write content to a file (overwrites)
- `append_file` - Append content to a file
- `replace_string` - Find and replace text in a file
- `multi_replace_string` - Batch replacements across files
- `insert_at_line` - Insert content at a specific line
- `rename_file` - Rename or move a file
- `delete_file` - Delete a file or directory
- `create_directory` - Create a directory (with parents)

**Authorization:** Auto-approved inside working directory

---

### math_operations

**Operations:** `calculate`, `compute`, `convert`, `formula`

- **calculate:** Evaluate mathematical expressions via Python
- **compute:** Run arbitrary Python code for complex calculations
- **convert:** Unit conversions (temperature, length, weight, volume, speed, data, time)
- **formula:** Named formulas (mortgage, compound_interest, tip, budget, debt_strategy, retirement, paycheck, loan_comparison, savings_goal, net_worth, and more)

**Key design:** Uses python3 subprocess for all computation to prevent LLM math hallucination.

---

### calendar_operations

**Uses EventKit for calendars and reminders**

**Calendar operations:** `list_events`, `create_event`, `search_events`, `delete_event`

**Reminder operations:** `list_reminders`, `create_reminder`, `complete_reminder`, `delete_reminder`, `list_reminder_lists`

---

### contacts_operations

**Uses Contacts framework**

**Operations:** `search`, `get_contact`, `create_contact`, `update_contact`, `list_groups`, `search_group`

---

### notes_operations

**Works with Apple Notes**

**Operations:** `search`, `get_note`, `create_note`, `list_folders`, `list_notes`, `append_note`

---

### spotlight_search

**Uses macOS Spotlight for file and metadata search**

**Operations:** `search`, `search_content`, `search_metadata`, `file_info`, `recent_files`

---

### weather_operations

**Uses Open-Meteo and SAM's configured location information**

**Operations:** `current`, `forecast`, `hourly`

---

### image_generation

**Remote image generation via ALICE server**

**Operations:** `generate`, `list_models`

Connects to a remote [ALICE](https://github.com/SyntheticAutonomicMind/ALICE) server for GPU-accelerated Stable Diffusion image and audio generation. No local GPU required. Only available when ALICE server is configured and reachable.

---

## Internal Tools (Not Directly Visible to LLM)

These are dispatched by consolidated tools:

| Internal Tool | Dispatched By |
|--------------|---------------|
| read_file, list_dir, get_file_info, get_errors | file_operations |
| file_search, grep_search, semantic_search, list_usages | file_operations |
| create_file, write_file, append_file, replace_string, multi_replace_string, insert_at_line, rename_file, delete_file, create_directory | file_operations |
| document_import, document_create, get_doc_info | document_operations |
| web_search, serpapi, scrape, fetch | web_operations |
| research, retrieve | web_operations |
| search_memory, store_memory, list_collections, recall_history | memory_operations |
| store, retrieve, search_kv, list_keys, delete_key | memory_operations |
| add_discovery, add_solution, add_pattern, ltm_stats, prune_ltm | memory_operations |
| read_tool_result | System (large result retrieval) |

---

## Tool Result Format

```swift
public struct MCPToolResult {
    var toolName: String
    var executionId: UUID?
    var success: Bool
    var output: MCPOutput
    var metadata: MCPResultMetadata?
}

public struct MCPOutput {
    var content: String
    var mimeType: String
    var additionalData: [String: Any]?
}
```

---

## Tool Cards in UI

When SAM runs a tool, the conversation shows a tool card with:
- Tool name
- Operation
- Parameters
- Status
- Result or failure output

This keeps autonomous behavior visible and inspectable.

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 2.0 | 2026-08-23 | Expanded to 12 consolidated tools, added macOS integration tools, detailed all operations |
| 1.4 | 2025-12-05 | Initial documentation |
| 1.0 | 2025-12-05 | Initial specification |

---

## See Also

- [MCP Tools Specification](MCP_TOOLS_SPECIFICATION.md) - Detailed tool parameter schemas
- [Tool Execution Flows](flows/TOOL_EXECUTION_FLOWS.md) - Execution flow diagrams
- [Agent Orchestrator](AGENT_ORCHESTRATOR.md) - How tools are called in workflows