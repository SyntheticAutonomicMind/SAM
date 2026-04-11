# SAM Tools Reference

What SAM can do autonomously with its built-in tool system.

---

## Overview

SAM uses a consolidated tool system that lets the model take action instead of only replying with text. When a request requires external capabilities, SAM can call the appropriate tool, inspect the result, and continue working.

You see this activity through tool cards in the conversation UI.

---

## How Tools Work

1. You ask SAM to do something
2. SAM decides which tool or tools are needed
3. The tool runs with structured parameters
4. SAM reads the result and either responds or continues the workflow

For multi-step work, SAM can chain tool calls together and track progress with a dedicated todo list.

---

## Current Tool Surface

The current built-in tool set includes:

- `user_collaboration`
- `memory_operations`
- `todo_operations`
- `web_operations`
- `document_operations`
- `file_operations`
- `math_operations`
- `calendar_operations`
- `contacts_operations`
- `notes_operations`
- `spotlight_search`
- `weather_operations`
- `image_generation`

Some tools are always present, while others depend on configuration or service availability.

For example, `image_generation` only becomes available when an ALICE server is configured and reachable.

---

## Collaboration and Planning

### `user_collaboration`

Used when SAM needs to pause and ask you something directly.

**Typical uses**
- Clarifying ambiguous requests
- Asking for approval before destructive actions
- Requesting information only you know
- Reporting blockers and asking how to proceed

### `todo_operations`

Used for multi-step tasks so SAM can plan, track, and surface progress.

**Operations**
- `read`
- `write`
- `update`
- `add`

This is how SAM keeps structured progress visible during longer workflows.

---

## Memory and Context

### `memory_operations`

SAM's memory tool covers both per-conversation memory and longer-lived memory features.

**Session memory operations**
- `search_memory`
- `store_memory`
- `recall_history`
- `list_collections`

**Key-value working memory**
- `store`
- `retrieve`
- `search_kv`
- `list_keys`
- `delete_key`

**Long-term memory operations**
- `add_discovery`
- `add_solution`
- `add_pattern`
- `ltm_stats`
- `prune_ltm`

This allows SAM to preserve conversational context, working notes, and learned patterns over time.

---

## File and Document Work

### `file_operations`

Used for reading, searching, and managing files.

**Read operations**
- `read_file`
- `list_dir`
- `get_file_info`
- `get_errors`
- `read_tool_result`

**Search operations**
- `file_search`
- `grep_search`
- `semantic_search`
- `list_usages`

**Write and management operations**
- `create_file`
- `replace_string`
- `multi_replace_string`
- `insert_edit`
- `rename_file`
- `delete_file`

**Authorization model**
- Inside the working directory: auto-approved
- Outside the working directory: requires authorization

### `document_operations`

Used for document import, document creation, and document inventory.

**Operations**
- `document_import`
- `document_create`
- `get_doc_info`

**Current document creation formats**
- `docx`
- `pdf`
- `txt`
- `markdown`
- `pptx`
- `rtf`
- `xlsx`

Document import is designed to feed content into conversation memory and semantic retrieval.

---

## Web and Research

### `web_operations`

Used for web search, retrieval, and structured research.

**Operations**
- `research`
- `retrieve`
- `web_search`
- `scrape`
- `fetch`
- `serpapi` when SerpAPI is configured and available

**Typical uses**
- Current events and live information
- Documentation lookup
- Product and recommendation research
- Pulling content from specific URLs

The `research` flow is the most comprehensive path and is designed for synthesis across multiple sources.

---

## Computation and Images

### `math_operations`

Used for real math, conversions, and structured formulas.

**Operations**
- `calculate`
- `compute`
- `convert`
- `formula`

This tool uses Python-backed computation rather than model guesswork.

### `image_generation`

Used for generating images through ALICE.

**Operations**
- `generate`
- `list_models`

This tool requires a working ALICE server and becomes available only when the service is configured and reachable.

---

## macOS Integration Tools

### `calendar_operations`

Uses EventKit to work with calendars and reminders.

**Calendar operations**
- `list_events`
- `create_event`
- `search_events`
- `delete_event`

**Reminder operations**
- `list_reminders`
- `create_reminder`
- `complete_reminder`
- `delete_reminder`
- `list_reminder_lists`

### `contacts_operations`

Uses the Contacts framework.

**Operations**
- `search`
- `get_contact`
- `create_contact`
- `update_contact`
- `list_groups`
- `search_group`

### `notes_operations`

Works with Apple Notes.

**Operations**
- `search`
- `get_note`
- `create_note`
- `list_folders`
- `list_notes`
- `append_note`

### `spotlight_search`

Uses macOS Spotlight for file and metadata search.

**Operations**
- `search`
- `search_content`
- `search_metadata`
- `file_info`
- `recent_files`

### `weather_operations`

Uses Open-Meteo and SAM's configured location information.

**Operations**
- `current`
- `forecast`
- `hourly`

---

## Tool Cards in the UI

When SAM runs a tool, the conversation shows a tool card with:

- Tool name
- Operation
- Parameters
- Status
- Result or failure output

This keeps autonomous behavior visible and inspectable.

---

## Safety Model

Tool use is constrained by:

- File authorization boundaries
- User collaboration checkpoints for sensitive work
- Preferences-controlled capabilities
- Service availability for optional integrations

That means SAM can be useful without silently overreaching.

---

## See Also

- [Features](FEATURES.md)
- [Memory](MEMORY.md)
- [Security](SECURITY.md)
- [User Guide](USER_GUIDE.md)
