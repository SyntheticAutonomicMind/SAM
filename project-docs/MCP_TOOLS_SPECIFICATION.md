# SAM: MCP Tools Specification

**Version:** 5.0
**Last Updated:** August 23, 2026
**Status:** Updated for 12 consolidated tools with macOS integration

## Overview

SAM uses a **consolidated tool architecture** where related operations are grouped under unified tools with an `operation` parameter. Internal sub-tools handle individual operations but are not directly visible to the LLM.

**Tool Count:** 12 consolidated tools exposed to the LLM (13 when ALICE is configured)
**Internal Operations:** ~80 sub-operations dispatched by consolidated tools

---

## Tool Registry (Ordered for KV Cache Consistency)

Tools are registered in a fixed order to maintain KV cache stability across requests:

| # | Tool Name | Purpose | Always Available |
|---|-----------|---------|-----------------|
| 1 | `user_collaboration` | Pause for user input mid-execution | Yes |
| 2 | `todo_operations` | Agent task tracking for multi-step work | Yes |
| 3 | `memory_operations` | Search/store conversation memories, LTM, KV store | Yes |
| 4 | `web_operations` | Web search, research, scraping, fetching | Yes |
| 5 | `document_operations` | Import/create PDF, DOCX, PPTX, XLSX, MD, RTF | Yes |
| 6 | `file_operations` | Read, search, write, manage files | Yes |
| 7 | `math_operations` | Mathematical calculations, formulas, unit conversions | Yes |
| 8 | `calendar_operations` | Calendar and reminder management (EventKit) | Yes* |
| 9 | `contacts_operations` | Contacts framework integration | Yes* |
| 10 | `notes_operations` | Apple Notes integration | Yes* |
| 11 | `spotlight_search` | macOS Spotlight file/metadata search | Yes* |
| 12 | `weather_operations` | Weather via Open-Meteo | Yes* |
| 13 | `image_generation` | Image generation via remote ALICE server | Conditional |

*Requires macOS permission grant on first use

---

## Authorization Model

**Path-based authorization:**
- Inside working directory: Auto-approved
- Outside working directory: Requires `user_collaboration`
- Relative paths: Auto-resolve to working directory

**Working Directories:**
- Per-conversation: `~/SAM/conversation-{number}/`
- Shared topics: `~/SAM/{topic-name}/`

**macOS Permissions:**
- Calendar/Reminders: EventKit access prompt
- Contacts: Contacts framework access prompt
- Notes: Notes app access prompt
- Spotlight: Uses system index, respects macOS privacy settings

---

## Tool Specifications

### 1. user_collaboration

**Pause for user input mid-execution**

**Operations:** `request_input`

**Parameters:**
```json
{
  "operation": "request_input",
  "prompt": "string (required) - Question for the user",
  "context": "string (optional) - Additional context"
}
```

**Use for:**
- Ambiguous requests needing clarification
- Multiple valid approaches - let user choose
- Confirmation before destructive operations
- Information only user knows

**Don't use for:**
- Questions answerable with other tools
- Information already in conversation context

**Response Format:**
```json
{
  "success": true,
  "output": {
    "content": "User's response",
    "mimeType": "text/plain"
  }
}
```

---

### 2. todo_operations

**Agent task tracking for multi-step work (NOT user todo lists)**

**Operations:** `read`, `write`, `update`, `add`

**Parameters:**
```json
// read
{ "operation": "read" }

// write
{ "operation": "write", "todoList": [{"title": "string", "description": "string", "status": "not-started|in-progress|completed|blocked", "priority": "low|medium|high|critical"}] }

// update
{ "operation": "update", "todoUpdates": [{"id": "integer", "status": "string", "progress": "number"}] }

// add
{ "operation": "add", "newTodos": [{"title": "string", "description": "string"}] }
```

**Workflow (ENFORCED):**
1. Create todo list for complex requests (`write`)
2. Mark ONE todo in-progress before starting (`update`)
3. Complete work on that specific todo
4. Mark completed immediately (`update`)
5. Move to next todo

**Orchestrator Enforcement:** Runtime guidance injected when todos exist

---

### 3. memory_operations

**Search and store conversation memories, LTM, and KV store**

**Operations:** 
- Session: `search_memory`, `store_memory`, `list_collections`, `recall_history`
- KV Store: `store`, `retrieve`, `search_kv`, `list_keys`, `delete_key`
- LTM: `add_discovery`, `add_solution`, `add_pattern`, `ltm_stats`, `prune_ltm`, `add_corroboration`, `update_ltm`

**Parameters (examples):**
```json
// search_memory
{ "operation": "search_memory", "query": "string", "limit": 10 }

// store_memory
{ "operation": "store_memory", "content": "string", "importance": 0.5, "tags": ["tag1"] }

// store (KV)
{ "operation": "store", "key": "string", "content": "string" }

// add_discovery (LTM)
{ "operation": "add_discovery", "fact": "string", "confidence": 0.8 }
```

**Similarity Thresholds:**
- Document/RAG: 0.15-0.25
- Conversation: 0.3-0.5
- No results: Lower incrementally

**LTM Trust Tiers:**
- `[UNVERIFIED]` - Single source, needs corroboration
- `[TRUSTED]` - 2+ independent corroborations

---

### 4. web_operations

**Operations:** `research`, `retrieve`, `web_search`, `serpapi`, `scrape`, `fetch`

**Parameters:**
```json
// research
{ "operation": "research", "query": "string", "max_sources": 10, "depth": "standard|deep" }

// web_search
{ "operation": "web_search", "query": "string", "max_results": 10, "engine": "google|bing|duckduckgo" }

// scrape
{ "operation": "scrape", "url": "string", "wait_for": "networkidle|domcontentloaded" }

// fetch
{ "operation": "fetch", "url": "string", "timeout": 30 }

// serpapi
{ "operation": "serpapi", "query": "string", "engine": "google|bing|amazon|ebay|tripadvisor|walmart|yelp" }
```

**Operation Details:**
- **research:** Comprehensive multi-source research + automatic memory storage + synthesis
- **retrieve:** Access previously stored research from memory
- **web_search:** Standard web search with configurable engine
- **serpapi:** Direct SerpAPI access for structured results (requires SerpAPI key)
- **scrape:** Full WebKit rendering with JavaScript support
- **fetch:** Fast HTTP fetch without JavaScript

---

### 5. document_operations

**Operations:** `document_import`, `document_create`, `get_doc_info`

**Parameters:**
```json
// document_import
{ "operation": "document_import", "file_path": "string", "conversation_id": "uuid" }

// document_create
{ "operation": "document_create", "format": "pdf|docx|pptx|txt|markdown|rtf|xlsx", "content": "string", "title": "string" }

// get_doc_info
{ "operation": "get_doc_info", "file_path": "string" }
```

**Supported Formats:**
- **Import:** PDF, DOCX, XLSX, TXT, MD, CSV
- **Create:** PDF, DOCX, PPTX, TXT, MD, RTF, XLSX

**Import Process:**
1. Text extraction with format-appropriate parser
2. Chunking with overlap for retrieval accuracy
3. Embedding via Apple NaturalLanguage framework
4. Storage in per-conversation vector database

---

### 6. file_operations

**Dispatches to internal operations for file management**

**Operations:** 
- Read: `read_file`, `list_dir`, `get_file_info`, `get_errors`, `read_tool_result`
- Search: `file_search`, `grep_search`, `semantic_search`, `list_usages`
- Write: `create_file`, `write_file`, `append_file`, `replace_string`, `multi_replace_string`, `insert_at_line`, `rename_file`, `delete_file`, `create_directory`

**Parameters (examples):**
```json
// read_file
{ "operation": "read_file", "path": "string", "start_line": 1, "end_line": 100 }

// grep_search
{ "operation": "grep_search", "query": "string", "pattern": "*.swift", "is_regex": false }

// create_file
{ "operation": "create_file", "path": "string", "content": "string" }

// replace_string
{ "operation": "replace_string", "path": "string", "old_string": "string", "new_string": "string" }
```

**Authorization:** Auto-approved inside working directory (`~/SAM/`)

---

### 7. math_operations

**Real computation via Python - no AI approximation**

**Operations:** `calculate`, `compute`, `convert`, `formula`

**Parameters:**
```json
// calculate
{ "operation": "calculate", "expression": "string" }

// compute
{ "operation": "compute", "code": "string" }

// convert
{ "operation": "convert", "value": 100, "from_unit": "fahrenheit", "to_unit": "celsius" }

// formula
{ "operation": "formula", "name": "mortgage", "parameters": {"principal": 350000, "rate": 0.065, "years": 30} }
```

**Available Formulas:**
`tip`, `mortgage`, `bmi`, `compound_interest`, `percentage`, `markup`, `discount`, `area_circle`, `area_rectangle`, `volume_cylinder`, `speed_distance_time`, `sales_tax`, `gpa`, `fuel_cost`, `cooking`, `retirement`, `debt_payoff`, `debt_strategy`, `budget`, `loan_comparison`, `savings_goal`, `net_worth`, `paycheck`, `inflation`

**Supported Units:**
- Temperature: fahrenheit, celsius, kelvin
- Length: miles, kilometers, feet, meters, inches, centimeters
- Weight: pounds, kilograms, ounces, grams
- Volume: gallons, liters, cups, milliliters
- Speed: mph, kmh, knots
- Data: bytes, kb, mb, gb, tb
- Time: seconds, minutes, hours, days

---

### 8. calendar_operations

**EventKit integration for calendars and reminders**

**Operations:** `list_events`, `create_event`, `search_events`, `delete_event`, `list_reminders`, `create_reminder`, `complete_reminder`, `delete_reminder`, `list_reminder_lists`

**Parameters:**
```json
// list_events
{ "operation": "list_events", "start_date": "ISO8601", "end_date": "ISO8601", "calendar": "string" }

// create_event
{ "operation": "create_event", "title": "string", "start_date": "ISO8601", "end_date": "ISO8601", "calendar": "string", "notes": "string" }

// create_reminder
{ "operation": "create_reminder", "title": "string", "due_date": "ISO8601", "list": "string", "notes": "string" }
```

**Requires:** macOS Calendar/Reminders permission

---

### 9. contacts_operations

**Contacts framework integration**

**Operations:** `search`, `get_contact`, `create_contact`, `update_contact`, `list_groups`, `search_group`

**Parameters:**
```json
// search
{ "operation": "search", "query": "string" }

// create_contact
{ "operation": "create_contact", "given_name": "string", "family_name": "string", "email": "string", "phone": "string" }
```

**Requires:** macOS Contacts permission

---

### 10. notes_operations

**Apple Notes integration**

**Operations:** `search`, `get_note`, `create_note`, `list_folders`, `list_notes`, `append_note`

**Parameters:**
```json
// search
{ "operation": "search", "query": "string" }

// create_note
{ "operation": "create_note", "title": "string", "body": "string", "folder": "string" }
```

**Requires:** macOS Notes permission

---

### 11. spotlight_search

**macOS Spotlight for file and metadata search**

**Operations:** `search`, `search_content`, `search_metadata`, `file_info`, `recent_files`

**Parameters:**
```json
// search
{ "operation": "search", "query": "string", "limit": 20 }

// search_content
{ "operation": "search_content", "query": "string", "file_types": ["pdf", "docx"] }
```

**Respects:** macOS Spotlight privacy settings

---

### 12. weather_operations

**Weather via Open-Meteo with SAM's configured location**

**Operations:** `current`, `forecast`, `hourly`

**Parameters:**
```json
// current
{ "operation": "current" }

// forecast
{ "operation": "forecast", "days": 7 }

// hourly
{ "operation": "hourly", "hours": 24 }
```

---

### 13. image_generation (Conditional)

**Remote image and audio generation via ALICE server**

**Only available when:** ALICE server configured and reachable

**Operations:** `generate`, `list_models`

**Parameters:**
```json
// generate
{ "operation": "generate", "prompt": "string", "model": "string", "width": 1024, "height": 1024, "steps": 20, "guidance_scale": 7.5 }

// list_models
{ "operation": "list_models" }
```

---

## Internal Tools (Not Directly Visible to LLM)

These are dispatched by consolidated tools:

| Internal Operation | Dispatched By |
|-------------------|---------------|
| read_file, list_dir, get_file_info, get_errors | file_operations |
| file_search, grep_search, semantic_search, list_usages | file_operations |
| create_file, write_file, append_file, replace_string, multi_replace_string, insert_at_line, rename_file, delete_file, create_directory | file_operations |
| document_import, document_create, get_doc_info | document_operations |
| web_search, serpapi, scrape, fetch | web_operations |
| research, retrieve | web_operations |
| search_memory, store_memory, list_collections, recall_history | memory_operations |
| store, retrieve, search_kv, list_keys, delete_key | memory_operations |
| add_discovery, add_solution, add_pattern, ltm_stats, prune_ltm, add_corroboration, update_ltm | memory_operations |
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
| 5.0 | 2026-08-23 | Expanded to 12 consolidated tools (+1 conditional), added macOS integration tools (calendar, contacts, notes, spotlight, weather), detailed all operations |
| 4.0 | 2026-04-07 | Post-consolidation update, 8 tools |
| 3.0 | 2025-12-13 | Complete rewrite for accuracy post-consolidation |
| 2.0 | 2025-12-11 | Added consolidation details |
| 1.0 | 2025-12-09 | Initial specification |

---

## See Also

- [MCP Framework](MCP_FRAMEWORK.md) - Architecture and overview
- [Tool Execution Flows](flows/TOOL_EXECUTION_FLOWS.md) - Execution flow diagrams
- [Agent Orchestrator](AGENT_ORCHESTRATOR.md) - How tools are called in workflows