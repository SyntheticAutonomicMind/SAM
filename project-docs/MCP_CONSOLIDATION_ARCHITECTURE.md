<!-- SPDX-License-Identifier: CC-BY-NC-4.0 -->
<!-- SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius) -->


# MCP Consolidation Architecture

**Status**: Complete (December 2025)  
**Current State**: 15 MCP Tools  
**Tool Reduction**: ~39 original tools → 15 current tools (62% reduction)  
**Token Reduction**: Significant reduction in system prompt size  
**TTFT Improvement**: Faster response times with consolidated tool descriptions

---

## Overview

SAM's MCP (Model Context Protocol) tools have been consolidated from ~39 individual tools into 15 tools, with the 4 major operational tools (file, memory, terminal, todo) using a unified operation-based interface. This consolidation reduces system prompt size while preserving all functionality and improving agent decision-making through clearer tool organization.

**Historical Note**: This document describes the CURRENT architecture (December 2025). An intermediate consolidation occurred in October 2025 where file operations were split into 3 separate tools (FileReadOperationsTool, FileSearchOperationsTool, FileWriteOperationsTool). These have since been unified into a single FileOperationsTool.

---

## Current Architecture

### Tool Categories

**Consolidated Operational Tools (4 tools with multiple operations each):**
1. `file_operations` - 16 operations (read, search, write files)
2. `memory_operations` - 3 operations (search, store, list memories)
3. `terminal_operations` - 11+ operations (run commands, manage sessions)
4. `todo_operations` - 4 operations (agent task list management)

**Single-Purpose Utility Tools (11 tools):**
5. `think` - Transparent reasoning and planning
6. `user_collaboration` - User input and approval
7. `run_subagent` - Delegate complex tasks
8. `increase_max_iterations` - Extend agentic loops
9. `list_system_prompts` - Query available system prompts
10. `list_mini_prompts` - Query available mini prompts
11. `recall_history` - Retrieve conversation history
12. `read_tool_result` - Read previous tool results
13. `build_version_control` - Build and version operations
14. `search_index` - Search workspace index
15. `working_directory_indexer` - Index working directory

### Directory Structure

```
Sources/MCPFramework/
├── Tools/                      # 15 MCP tools (what agents see)
│   ├── FileOperationsTool.swift
│   ├── MemoryOperationsTool.swift
│   ├── TerminalOperationsTool.swift
│   ├── TodoOperationsTool.swift
│   ├── ThinkTool.swift
│   ├── UserCollaborationTool.swift
│   ├── RunSubagentTool.swift
│   ├── IncreaseMaxIterationsTool.swift
│   ├── ListSystemPromptsTool.swift
│   ├── ListMiniPromptsTool.swift
│   ├── RecallHistoryTool.swift
│   ├── ReadToolResultTool.swift
│   ├── BuildVersionControlTool.swift
│   ├── SearchIndexTool.swift
│   └── WorkingDirectoryIndexer.swift
│
├── MCPToolRegistry.swift       # Tool registration and lookup
├── MCPManager.swift            # Tool execution coordinator
└── Protocols/
    ├── MCPTool.swift          # Base tool protocol
    └── ConsolidatedMCP.swift  # Protocol for operation-based tools
```

---

## Consolidation Pattern: Operation-Based Interface

### How Consolidated Tools Work

Consolidated tools use an **operation parameter** to route to specific functionality:

```json
{
  "tool": "file_operations",
  "operation": "read_file",
  "filePath": "/path/to/file.swift",
  "startLine": 1,
  "endLine": 100
}
```

**Benefits:**
- **Reduced Token Count**: One tool description covers multiple operations
- **Logical Grouping**: Related operations grouped by domain (files, memory, etc.)
- **Clear Intent**: Tool names clearly indicate purpose
- **Extensibility**: New operations can be added without new tools

---

## Detailed Tool Specifications

### 1. file_operations (16 operations)

**Purpose**: Unified file system interface - read, search, write, and manage workspace files

**Operations:**

**READ (4 operations):**
- `read_file` - Read file content with optional line range
- `list_dir` - List directory contents
- `get_errors` - Get compilation/lint errors from workspace
- `get_search_results` - Get workspace search view results

**SEARCH (5 operations):**
- `file_search` - Find files by glob pattern (e.g., `**/*.swift`)
- `grep_search` - Text search with regex support
- `semantic_search` - AI-powered code search
- `list_usages` - Find all references to a symbol
- `search_index` - Search indexed files by extension

**WRITE (7 operations):**
- `create_file` - Create new file
- `replace_string` - Replace text in file
- `multi_replace_string` - Multiple replacements in one call
- `insert_edit` - Insert/replace at line number
- `rename_file` - Rename or move file
- `delete_file` - Delete file
- `apply_patch` - Apply patch file

**Authorization:**
- Inside working directory: AUTO-APPROVED
- Outside working directory: Requires `user_collaboration`
- Relative paths: Auto-resolved to working directory

**Replaces Historical Tools:**
- FileReadOperationsTool (intermediate consolidation Oct 2025)
- FileSearchOperationsTool (intermediate consolidation Oct 2025)
- FileWriteOperationsTool (intermediate consolidation Oct 2025)
- Individual tools: read_file, list_dir, create_file, replace_string, etc. (pre-consolidation)

**Example:**
```json
{
  "tool": "file_operations",
  "operation": "grep_search",
  "query": "TODO.*urgent",
  "isRegexp": true,
  "includePattern": "**/*.swift"
}
```

---

### 2. memory_operations (3 operations)

**Purpose**: Semantic memory search and storage for conversation context

**Operations:**
- `search_memory` - Query memories with natural language (semantic similarity search)
- `store_memory` - Save new memory to database
- `list_collections` - View memory statistics

**Similarity Threshold Guide:**
- Document/RAG: 0.15-0.25 (lower scores typical)
- Conversation memory: 0.3-0.5
- No results? Lower threshold: 0.3 → 0.2 → 0.15

**Note**: For todo list management, use `todo_operations` tool (separate concern)

**Replaces Historical Tools:**
- memory_search (pre-consolidation)
- store_memory (pre-consolidation)

**Example:**
```json
{
  "tool": "memory_operations",
  "operation": "search_memory",
  "query": "previous conversations about testing",
  "similarity_threshold": 0.3
}
```

---

### 3. terminal_operations (11+ operations)

**Purpose**: Terminal command execution and session management

**Operations:**
- `run_command` - Execute terminal command
- `get_terminal_output` - Get output from previous command
- `get_terminal_buffer` - Get full terminal buffer
- `get_last_command` - Get last executed command
- `get_terminal_selection` - Get current terminal selection
- `create_directory` - Create directory
- `create_session` - Create new terminal session
- `send_input` - Send input to session
- `get_output` - Get session output
- `get_history` - Get session history
- `close_session` - Close terminal session

**Authorization:**
- Commands require user approval based on risk level
- Directory creation inside working dir: AUTO-APPROVED
- Elevated permissions: Requires `user_collaboration`

**Replaces Historical Tools:**
- run_in_terminal
- get_terminal_output
- terminal_last_command
- terminal_selection
- create_and_run_task
- Individual session management tools

**Example:**
```json
{
  "tool": "terminal_operations",
  "operation": "run_command",
  "command": "swift build",
  "isBackground": false
}
```

---

### 4. todo_operations (4 operations)

**Purpose**: Agent workflow tracking and task list management

**CRITICAL NOTE**: This is for AGENT workflow tracking, NOT user personal todos. Agents use this to maintain their own task lists and execution plans.

**Operations:**
- `read` - Read current todo list
- `write` - Write/replace entire todo list
- `update` - Update specific todo item
- `add` - Add new todo item

**Use Cases:**
- Sequential task execution
- Multi-step workflow tracking
- Agent planning and organization
- Progress tracking across sessions

**Example:**
```json
{
  "tool": "todo_operations",
  "operation": "read"
}
```

---

### 5-15. Single-Purpose Tools

These tools perform one specific function and don't use the operation parameter pattern:

**5. think**
- Transparent reasoning and planning before responding
- Chain-of-Thought (CoT) reasoning
- No code execution, logs thought process

**6. user_collaboration**
- Request user input or approval
- Critical for authorization flow
- Enables human-in-the-loop operations

**7. run_subagent**
- Delegate complex tasks to focused sub-agents
- Useful for large, systematic work
- Sub-agent inherits context but works independently

**8. increase_max_iterations**
- Extend agentic loop iteration limit
- Use when complex tasks require more steps
- Default limit prevents infinite loops

**9. list_system_prompts**
- Query available system prompts
- Agents can see what prompt configurations exist

**10. list_mini_prompts**
- Query available mini prompts
- Smaller prompt templates for specific tasks

**11. recall_history**
- Retrieve conversation history
- Access to previous messages and context

**12. read_tool_result**
- Read results from previous tool executions
- Useful when tool output was large/truncated

**13. build_version_control**
- Build and version control operations
- Project-specific tooling

**14. search_index**
- Search workspace index
- Fast file discovery

**15. working_directory_indexer**
- Index working directory for search
- Maintains file index for fast lookups

---

## Tool Discovery and Selection

### How Agents See Tools

Tools are exposed to agents through the system prompt with their descriptions. The LLM:
1. Reads tool descriptions
2. Selects appropriate tool based on user request
3. Generates tool call with required parameters
4. Receives tool result and continues conversation

### Dotted Name Resolution

Some LLMs may generate dotted tool names instead of using the operation parameter:

```json
{"name": "file_operations.read_file", ...}
```

**MCPManager automatically resolves this to:**
```json
{"name": "file_operations", "operation": "read_file", ...}
```

This provides backwards compatibility and flexibility in how LLMs invoke tools.

---

## Authorization and Security

### Security Levels

- **Safe**: No authorization required (read operations, memory search)
- **Standard**: Authorization required outside working directory
- **Elevated**: Always requires authorization (delete, system modifications)

### Authorization Flow

1. Tool checks if operation requires authorization
2. If required, returns `MCPToolResult(requiresAuthorization: true)`
3. AgentOrchestrator invokes `user_collaboration` tool
4. User approves/rejects
5. If approved, tool execution retries with authorization granted

### Working Directory Sandboxing

- Each conversation has isolated working directory
- File writes inside working directory: AUTO-APPROVED
- File writes outside working directory: Requires approval
- Prevents accidental system modifications

---

## Evolution History

### Phase 1: Pre-Consolidation (Pre-October 2025)
- ~39 individual tools
- Each file operation was separate tool
- Large system prompts
- Slower response times

### Phase 2: Intermediate Consolidation (October 26, 2025)
- File operations split into 3 tools:
  - FileReadOperationsTool (4 operations)
  - FileSearchOperationsTool (4 operations)
  - FileWriteOperationsTool (6 operations)
- Memory and terminal consolidated
- Todo management separated

### Phase 3: Current State (December 2025)
- File operations fully unified into ONE FileOperationsTool (16 operations)
- 4 major operational tools + 11 utility tools
- Optimized descriptions
- Dotted name resolution support
- Enhanced authorization model

---

## References

- Tool Implementations: `Sources/MCPFramework/Tools/*.swift`
- Tool Specification: `project-docs/MCP_TOOLS_SPECIFICATION.md`
- MCP Framework: `project-docs/MCP_FRAMEWORK.md`
- Tool Execution Flow: `project-docs/flows/tool_execution_flow.md`

---

**Document Status**: Complete and verified against source code (December 13, 2025)
