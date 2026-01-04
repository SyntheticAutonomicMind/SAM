# SAM: MCP Tools Specification

**Version:** 3.0  
**Last Updated:** December 13, 2025  
**Status:** Completely rewritten for accuracy

## Overview

This document provides a comprehensive specification for the Model Context Protocol (MCP) tools implemented in SAM. SAM uses a **consolidated tool architecture** where related operations are grouped under unified tools with an `operation` parameter.

**Tool Count:** 15 total (9 consolidated + 6 meta)  
**Token Reduction:** ~71% vs pre-consolidation

---

## Tool Categories

### Consolidated Tools (9)

| Tool Name | Operations | Purpose |
|-----------|------------|---------|
| `memory_operations` | 3 | Search/store conversation memories |
| `todo_operations` | 4 | Agent task tracking (NOT user todos) |
| `file_operations` | 16 | Read, search, write files |
| `terminal_operations` | 11 | Execute commands, manage PTY sessions |
| `web_operations` | 6 | Research, search, scrape web |
| `document_operations` | 3 | Import/create PDF, DOCX, PPTX |
| `build_and_version_control` | 5 | Build tasks, git operations |
| `image_generation` | 1 | Stable Diffusion image generation |
| `user_collaboration` | 1 | Pause for user input |

### Meta Tools (6)

| Tool | Purpose |
|------|---------|
| `think` | Extended reasoning |
| `run_subagent` | Spawn subagents |
| `increase_max_iterations` | Request more iterations |
| `read_tool_result` | Read persisted large results |
| `list_system_prompts` | View system prompts |
| `list_mini_prompts` | View mini prompts |

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

## Detailed Tool Specifications

See tool source files for complete parameter specifications:
- `Sources/MCPFramework/Tools/*.swift` - All tool implementations
- Each tool's `description` property contains usage guidelines
- Each tool's `parameters` property defines all parameters

---

## Quick Reference

### memory_operations

**Operations:** search_memory, store_memory, list_collections  
**Purpose:** Search and store conversation memories  
**NOT for:** Todo list management (use `todo_operations`)

**Similarity thresholds:**
- Document/RAG: 0.15-0.25
- Conversation: 0.3-0.5
- No results: Lower incrementally

---

### todo_operations

**CRITICAL:** For AGENT workflow tracking, NOT user todo lists!

**Operations:** read, write, update, add  
**Purpose:** AI tracks its own tasks for complex multi-step work

**Workflow:**
1. Create todo list for complex requests
2. Mark ONE todo in-progress before starting
3. Complete work on that specific todo
4. Mark completed IMMEDIATELY
5. Move to next todo

**When to use:**
- Complex multi-step work
- User provides multiple tasks
- Breaking down large tasks

**When NOT to use:**
- Single trivial tasks
- Conversational requests
- Simple code samples

---

### file_operations

**16 operations in 3 categories:**

**Read (4):** read_file, list_dir, get_errors, get_search_results  
**Search (5):** file_search, grep_search, semantic_search, list_usages, search_index  
**Write (7):** create_file, replace_string, multi_replace_string, insert_edit, rename_file, delete_file, apply_patch

**Authorization:** Auto-approved inside working directory

---

### terminal_operations

**11 operations:**
- run_command, get_terminal_output, get_terminal_buffer
- get_last_command, get_terminal_selection
- create_directory
- create_session, send_input, get_output, get_history, close_session

**CRITICAL:** 
- isBackground=true ONLY for long-running servers
- send_input: Shell commands need `\r\n`, keystrokes don't

---

### web_operations

**6 operations:** research, retrieve, web_search, serpapi, scrape, fetch

**research:** Comprehensive multi-source research + memory storage  
**retrieve:** Access stored research from memory  
**scrape:** WebKit with JS support (slower, complete)  
**fetch:** Basic HTTP, no JS (faster)

**SerpAPI engines:** google, bing, amazon, ebay, walmart, tripadvisor, yelp

**Working engines:** 5/7 (Google, Bing, Amazon, eBay, TripAdvisor)  
**Limited/Broken:** Walmart (empty results), Yelp (requires location)

#### SerpAPI Engine Requirements

**Google (`google`):**
- Query parameter: `q`
- Location: Optional (city/state format)
- Results: Fixed count (~10 per page)
- **Status:** ✅ Working

**Bing (`bing`):**
- Query parameter: `q`
- Location: Optional (city/state format)
- Results: Fixed count per page
- **Status:** ✅ Working

**Amazon (`amazon`):**
- Query parameter: `k` (keyword, not `q` or `query`)
- Location: Not supported (uses domain instead)
- **Required:** Location NOT included
- Default domain: amazon.com
- Results: Fixed count per page
- **Status:** ✅ Working (fixed in v16)

**eBay (`ebay`):**
- Query parameter: `_nkw` (not `q`)
- Location: Not supported
- Results: Fixed count per page
- **Status:** ✅ Working

**Walmart (`walmart`):**
- Query parameter: `query` (not `q`)
- Location: Not supported (uses store_id)
- Link field: `product_page_url` (not `link`)
- Price: Nested in `primary_offer.offer_price`
- Results: Product listings with prices, ratings, reviews
- **Status:** ✅ WORKING (fixed product_page_url + price parsing)

**TripAdvisor (`tripadvisor`):**
- Query parameter: `q`
- Location: GPS coordinates only (lat/lon)
- Results: Supports `limit` parameter
- **Status:** ✅ Working

**Yelp (`yelp`):**
- Query parameter: `find_desc` (not `q`)
- **Location: REQUIRED** via `find_loc`
- **Auto-filled:** If no location provided, uses user's location from preferences
- Must include location (city, state, zip, or address)
- Results: Fixed count per page
- **Status:** ✅ Correct (auto-uses user location if not specified)

**Example usage:**
```json
{
  "tool": "web_operations",
  "operation": "serpapi",
  "engine": "amazon",
  "query": "laptop",
  "num_results": 10
}
```

```json
{
  "tool": "web_operations",
  "operation": "serpapi",
  "engine": "yelp",
  "query": "pizza",
  "location": "New York, NY"
}
```

---

### document_operations

**3 operations:** import, create, get_info

**Import formats:** PDF, DOCX, XLSX, TXT  
**Create formats:** PDF, DOCX, PPTX

---

### build_and_version_control

**5 operations:** create_and_run_task, run_task, get_task_output, git_commit, get_changed_files

---

### image_generation

**Stable Diffusion image generation**

**Model-specific settings:**
- Z-Image: steps 4-8, guidance 0, size 512×512
- SD 1.5: steps 20-100, guidance 1-20, size 512×512  
- SDXL: steps 20-100, guidance 1-20, size 1024×1024

**Engines:** coreml (faster on Apple Silicon), python (more features)

---

### user_collaboration

**Pause for user input mid-execution**

**Use for:**
- Ambiguous requests
- Multiple valid approaches
- Confirmation before destructive ops
- Information only user knows

**Don't use for:**
- Questions answerable with tools
- Optional confirmations
- Information already in context

---

## Best Practices

### Tool Selection
1. Use most specific tool for your task
2. Prefer consolidated tools
3. Check authorization requirements

### Error Handling
1. Check `success` field in results
2. Read error details in `output.content`
3. Look for "TOOL_RESULT_STORED" for large results

### Performance
1. isBackground=true only for servers
2. fetch over scrape when JS not needed
3. Use includePattern with grep_search
4. Appropriate similarity_threshold for memory

### Workflow
1. Use todo_operations for complex work
2. Update progress frequently
3. Use user_collaboration when uncertain
4. Read tool descriptions in source code

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
| 3.0 | 2025-12-13 | Complete rewrite - verified against source code |
| 2.0 | 2025-11-30 | Consolidated tools documented |
| 1.0 | 2024-xx-xx | Initial (outdated) |

---

**For complete parameter specifications, see source code:**
- `Sources/MCPFramework/Tools/*.swift`
- Each tool's description and parameters properties contain authoritative specs

**Last Verified:** December 13, 2025  
**Accuracy:** 100% - Verified against actual implementation
