# SAM: MCP Tools Specification

**Version:** 4.0
**Last Updated:** April 7, 2026
**Status:** Updated post-consolidation

## Overview

SAM uses a **consolidated tool architecture** where related operations are grouped under unified tools with an `operation` parameter. Internal sub-tools handle individual operations but are not directly visible to the LLM.

**Tool Count:** 8 consolidated tools exposed to the LLM
**Internal Tools:** ~21 sub-tools dispatched by consolidated tools

---

## Tool Registry (Ordered)

Tools are registered in a fixed order for KV cache consistency:

| # | Tool Name | Purpose |
|---|-----------|---------|
| 1 | `user_collaboration` | Pause for user input mid-execution |
| 2 | `memory_operations` | Search/store conversation memories, recall history |
| 3 | `todo_operations` | Agent task tracking for multi-step work |
| 4 | `web_operations` | Web search, research, scraping, fetching |
| 5 | `document_operations` | Import/create PDF, DOCX, PPTX, XLSX |
| 6 | `file_operations` | Read, search, write, manage files |
| 9 | `math_operations` | Mathematical calculations, formulas, unit conversions |
| 10 | `image_generation` | Image generation via remote ALICE server |

---

## Authorization Model

**Path-based authorization:**
- Inside working directory: Auto-approved
- Outside working directory: Requires `user_collaboration`
- Relative paths: Auto-resolve to working directory

**Working Directories:**
- Per-conversation: `~/SAM/conversation-{number}/`
- Shared topics: `~/SAM/{topic-name}/`

---

## Tool Specifications

### user_collaboration

**Pause for user input mid-execution**

**Use for:**
- Ambiguous requests needing clarification
- Multiple valid approaches - let user choose
- Confirmation before destructive operations
- Information only user knows

**Don't use for:**
- Questions answerable with other tools
- Information already in conversation context

---

### memory_operations

**Operations:** search_memory, store_memory, list_collections, recall_history
**Purpose:** Search and store conversation memories, recall topic history

**Similarity thresholds:**
- Document/RAG: 0.15-0.25
- Conversation: 0.3-0.5
- No results: Lower incrementally

---

### todo_operations

**Operations:** read, write, update, add
**Purpose:** Agent tracks its own tasks for complex multi-step work (NOT user todo lists)

**Workflow:**
1. Create todo list for complex requests
2. Mark ONE todo in-progress before starting
3. Complete work on that specific todo
4. Mark completed immediately
5. Move to next todo

---

### web_operations

**Operations:** research, retrieve, web_search, serpapi, scrape, fetch

- **research:** Comprehensive multi-source research + memory storage
- **retrieve:** Access stored research from memory
- **scrape:** WebKit with JS support (slower, complete)
- **fetch:** Basic HTTP, no JS (faster)
- **serpapi:** Direct SerpAPI access (Google, Bing, Amazon, eBay, TripAdvisor, Walmart, Yelp)

---

### document_operations

**Operations:** import, create, get_info

- **Import formats:** PDF, DOCX, XLSX, TXT
- **Create formats:** PDF, DOCX, PPTX

---

### file_operations

**Dispatches to internal tools for:**
- **Read:** read_file, list_dir, get_errors
- **Search:** file_search, grep_search, semantic_search, list_code_usages
- **Write:** create_file, replace_string, multi_replace_string, insert_edit, rename_file, delete_file

**Authorization:** Auto-approved inside working directory

---

### math_operations

**Operations:** calculate, compute, convert, formula

- **calculate:** Evaluate mathematical expressions via Python
- **compute:** Run arbitrary Python code for complex calculations
- **convert:** Unit conversions (temperature, length, weight, volume, speed, data, time)
- **formula:** Named formulas (mortgage, compound_interest, tip, budget, debt_strategy, retirement, paycheck, loan_comparison, savings_goal, net_worth, and more)

**Key design:** Uses python3 subprocess for all computation to prevent LLM math hallucination.

---

### image_generation

**Remote image generation via ALICE server**

Connects to a remote [ALICE](https://github.com/SyntheticAutonomicMind/ALICE) server for GPU-accelerated Stable Diffusion image generation. No local GPU required.

---

## Internal Tools (Not Directly Visible to LLM)

These are dispatched by consolidated tools:

| Internal Tool | Dispatched By |
|--------------|---------------|
| read_file, list_dir, get_errors | file_operations |
| file_search, grep_search, semantic_search | file_operations |
| list_code_usages | file_operations |
| create_file, replace_string, multi_replace_string | file_operations |
| insert_edit, rename_file, delete_file | file_operations |
| create_directory | file_operations |
| fetch_webpage | web_operations |
| read_tool_result | System (large result retrieval) |
| recall_history | memory_operations |

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

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 4.0 | 2026-03-12 | Removed SD/Training/subagent tools. Added math_operations. Removed terminal_operations and version_control. Updated tool count to 8. |
| 3.0 | 2025-12-13 | Complete rewrite for accuracy post-consolidation |
| 2.0 | 2025-12-11 | Added consolidation details |
| 1.0 | 2025-12-09 | Initial specification |
