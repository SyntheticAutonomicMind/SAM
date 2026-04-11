# SAM Features

**Complete feature reference for SAM (Synthetic Autonomic Mind)**

---

## Overview

SAM is a native macOS AI assistant with a comprehensive set of features for conversation, research, document management, file operations, image generation, math, and voice control. This document covers every feature in detail.

---

## Conversations

### Unlimited Conversations

Create as many conversations as you want. Each one is saved automatically to `~/Library/Application Support/SAM/conversations/` and persists across app restarts.

### Automatic Saving

Every message is saved as it's sent. You never need to manually save. If SAM crashes or you force-quit, your conversations are preserved.

### Conversation Export

Export any conversation in two formats:
- **JSON** - Full structured export with metadata, timestamps, and tool calls
- **Markdown** - Human-readable format suitable for sharing or archiving

### Conversation Import

Import previously exported conversations back into SAM.

### Context Isolation

Conversations are isolated by default. The AI in one conversation has no knowledge of other conversations. This is a privacy feature - you can have a work conversation and a personal conversation without cross-contamination.

To share context between conversations, use [Shared Topics](#shared-topics).

### Model Switching

Switch AI models at any point during a conversation. The full conversation history carries forward to the new model. Useful for starting with a fast model and switching to a more capable one for complex tasks.

### Per-Conversation Settings

Each conversation stores its own UI state:
- Panel visibility (tool cards, performance, etc.)
- Scroll position
- Active model

---

## AI Provider Support

### Cloud Providers

**OpenAI**
- Models: GPT-4o, GPT-4, GPT-3.5 Turbo, o1, o3
- Streaming support with real-time token delivery
- Function calling and tool use

**GitHub Copilot**
- Models: GPT-4o, Claude 3.5, o1 (varies by subscription)
- Device flow authentication (no manual API key needed)
- Automatic token refresh

**DeepSeek**
- Models: DeepSeek Chat, DeepSeek Coder
- Cost-effective alternative for coding and general tasks

**Google Gemini**
- Models: Gemini 2.5 Pro, Gemini 2.5 Flash, Gemini 2.0 Flash
- Large context windows (up to 1M tokens)
- Strong multimodal capabilities

**MiniMax**
- Models: MiniMax-M2.7, MiniMax-M2.5, high-speed variants
- 128K token context window
- Competitive pricing with good tool use

**OpenRouter**
- Access 100+ models from multiple providers through a single API
- Automatic model routing and load balancing

> **Note on Claude models:** SAM does not include a direct Anthropic provider. Claude-family models are available through GitHub Copilot (if your subscription includes them) and OpenRouter.

### Local Models

**MLX (Apple Silicon)**
- Runs models using Apple's MLX framework
- Metal GPU acceleration for fast inference
- Efficient memory usage with unified memory architecture
- Support for Hugging Face model format
- Model caching and lazy loading
- LRU eviction for memory management

**llama.cpp (Any Mac)**
- Runs GGUF-format models on Apple Silicon or Intel
- Compiled as a native framework (included as git submodule)
- CPU and GPU inference modes

### Model Download Manager

- Browse available models from Hugging Face
- Download progress tracking with pause/resume
- Model size estimates before download
- Automatic storage management

### Custom Endpoints

Connect to any OpenAI-compatible API:
- Local servers (Ollama, LM Studio, text-generation-webui)
- Self-hosted inference servers
- Custom routing proxies

---

## Autonomous Tool System

SAM has 8 consolidated tools that the AI uses autonomously to accomplish tasks. Each consolidated tool contains multiple operations.

### File Operations

| Operation | What It Does |
|-----------|-------------|
| `read_file` | Read file content with optional line range |
| `list_dir` | List directory contents (recursive or flat) |
| `get_errors` | Check a file for compilation/lint errors |
| `get_file_info` | Get file metadata (size, type, modified time) |
| `read_tool_result` | Read large results in chunks |
| `file_search` | Find files matching a glob pattern |
| `grep_search` | Search file contents with text or regex |
| `semantic_search` | Find files by meaning using NLP |
| `list_usages` | Find all references to a symbol |
| `create_file` | Create a new file with content |
| `replace_string` | Find and replace text in a file |
| `multi_replace_string` | Batch replacements across files |
| `insert_edit` | Insert content at a specific location |
| `rename_file` | Rename or move a file |
| `delete_file` | Delete a file or directory |
| `create_directory` | Create a directory (with parents) |

**Path Authorization:**
- Inside `~/SAM/` working directory: auto-approved
- Outside working directory: requires user confirmation

### Web Operations

| Operation | What It Does |
|-----------|-------------|
| `research` | Multi-source web research with automatic memory storage |
| `retrieve` | Access previously stored research |
| `web_search` | Search the web (Google, Bing, DuckDuckGo) |
| `serpapi` | Direct SerpAPI access (Google, Bing, Amazon, eBay, TripAdvisor, Walmart, Yelp) |
| `scrape` | Full WebKit page rendering with JavaScript support |
| `fetch` | Fast HTTP fetch without JavaScript |

**Research** is SAM's most powerful web tool. It conducts multi-source research, synthesizes findings, and stores results in conversation memory for future reference.

### Document Operations

| Operation | What It Does |
|-----------|-------------|
| `document_import` | Import PDF, DOCX, XLSX, or TXT files into the conversation |
| `document_create` | Generate PDF, DOCX, PPTX, TXT, or Markdown files |
| `get_doc_info` | Get document metadata |

Imported documents are chunked and indexed with vector embeddings for semantic search.

### Memory Operations

| Operation | What It Does |
|-----------|-------------|
| `search_memory` | Semantic search across conversation memories |
| `store_memory` | Save important information for later |
| `list_collections` | List available memory collections |
| `recall_history` | Recall conversation history by topic |

### Todo Operations

| Operation | What It Does |
|-----------|-------------|
| `read` | Get current task list |
| `write` | Create or replace task list |
| `update` | Update task status |
| `add` | Add new tasks |

The AI uses todos to track multi-step work. It creates a plan, marks tasks in-progress as it works, and marks them complete as it finishes.

### Math Operations

| Operation | What It Does |
|-----------|-------------|
| `calculate` | Evaluate mathematical expressions via Python |
| `compute` | Run arbitrary Python code for complex calculations |
| `convert` | Unit conversions (temperature, length, weight, volume, speed, data, time) |
| `formula` | Named financial and practical formulas |

**Available Formulas:**
tip, mortgage, bmi, compound_interest, percentage, markup, discount, area_circle, area_rectangle, volume_cylinder, speed_distance_time, sales_tax, gpa, fuel_cost, cooking, retirement, debt_payoff, debt_strategy, budget, loan_comparison, savings_goal, net_worth, paycheck, and inflation.

All math is computed by a real Python 3 interpreter - no AI approximation.

### Image Generation

| Operation | What It Does |
|-----------|-------------|
| `generate` | Generate images from text descriptions |

Connects to a remote [ALICE](https://github.com/SyntheticAutonomicMind/ALICE) server for GPU-accelerated Stable Diffusion image generation. Supports multiple models, automatic model discovery, and server health monitoring.

### User Collaboration

| Operation | What It Does |
|-----------|-------------|
| `request_input` | Pause and ask the user a question |

Used by the AI when it needs clarification, confirmation for destructive operations, or user decisions.

---

## Memory System

### Vector RAG (Retrieval-Augmented Generation)

SAM uses vector embeddings to index conversations and documents for semantic search. This means you can find information by meaning, not just keywords.

**How it works:**
1. Text is split into chunks
2. Each chunk gets a vector embedding via Apple's NaturalLanguage framework
3. Embeddings are stored in a per-conversation SQLite database
4. Queries are embedded and matched against stored vectors
5. Top matches are returned with similarity scores

### Cross-Conversation Search

Search across all conversations simultaneously. The search interface uses the same semantic matching to find relevant discussions regardless of exact wording.

### Document Import and Search

Import documents into any conversation. The content is chunked, embedded, and stored for semantic retrieval. You can then ask questions about the document naturally.

**Supported Formats:** PDF, DOCX, XLSX, TXT, MD, CSV

### Context Window Management

SAM uses context archival to manage long conversations:
- Messages are archived to a per-conversation SQLite database when the context window fills
- Archived chunks include summaries, key topics, and timestamps
- Semantic search retrieves relevant archived context automatically
- Pinned messages are preserved and always included in context
- Dynamic context sizing based on model limits

---

## Voice Control

### Wake Word Detection

Say "Hey SAM" to activate voice input. Uses Apple's on-device speech recognition for privacy.

### Speech-to-Text

Real-time speech transcription using Apple's Speech framework. All processing happens on-device.

### Text-to-Speech

SAM speaks responses aloud using macOS native voices:
- **Streaming TTS** - Starts speaking as soon as the first sentence is ready
- **Markdown stripping** - Removes formatting before speaking
- **Voice selection** - Choose from any installed macOS voice
- **Speed control** - Adjustable rate from 0.5x to 1.5x

### Audio Device Management

Select specific input (microphone) and output (speaker) devices. SAM detects all connected audio devices and updates the list when devices change.

---

## Image Generation (ALICE)

Connect to a remote [ALICE](https://github.com/SyntheticAutonomicMind/ALICE) server for Stable Diffusion image generation:

- **Automatic model discovery** - Detects models loaded on the ALICE server
- **Multiple model support** - SD 1.5, SDXL, and custom models
- **Health monitoring** - Connection status and server availability
- **No local GPU required** - Generation happens on the ALICE server
- **In-chat display** - Generated images appear directly in the conversation

---

## SAM-Web (Remote Access)

Access SAM from any device on your local network through a web browser.

**Features:**
- Full chat interface
- Mini-prompts
- Model selection
- Conversation management
- Responsive design (desktop, tablet, mobile)
- Token-based authentication

**Requirements:**
- SAM running on your Mac with API server enabled
- [SAM-Web](https://github.com/SyntheticAutonomicMind/SAM-web) deployed
- Both devices on the same network

---

## Shared Topics

Cross-conversation workspaces backed by SQLite:

- **Named topics** - Create topics for projects, research areas, or any ongoing work
- **Shared workspace** - All conversations in a topic share a file directory
- **Shared entries** - Store and retrieve data accessible to any conversation in the topic
- **Optimistic locking** - Safe concurrent access from multiple conversations
- **Audit trail** - All operations are logged

---

## System Prompt Customization

### Built-In Personalities

SAM includes personality configurations that affect communication style:
- Tone, vocabulary, and response style
- Configurable personality traits
- Per-conversation or global settings

### Custom System Prompts

Edit the system prompt that defines SAM's behavior:
- View and modify the active system prompt
- Save custom system prompt templates
- Switch between configurations
- Component library for building modular prompts

### Mini-Prompts

Quick-action templates for common tasks. Mini-prompts provide pre-configured instructions that you can invoke with a click instead of typing out full instructions each time.

---

## API Server

SAM runs a local HTTP server (Vapor-based) that provides:

- **OpenAI-compatible API** - Connect external tools that speak the OpenAI protocol
- **SAM-Web interface** - Web-based access from other devices
- **Authentication** - Token-based auth for all API endpoints
- **SSE streaming** - Real-time streaming responses
- **CORS support** - Configurable cross-origin access

The server runs on port 8080 by default and is disabled until explicitly enabled in Settings.

---

## Performance Monitoring

Real-time metrics visible in the app:

- **Memory (RSS)** - Application memory usage
- **Inference speed** - Tokens per second for local models
- **Context usage** - Current token count vs. model limit
- **API latency** - Response time for cloud providers

---

## Auto-Updates (Sparkle)

SAM uses the Sparkle framework for automatic updates:

- **Stable channel** - Production releases (default)
- **Development channel** - Pre-release builds (opt-in in Settings)
- **Background checks** - SAM checks for updates periodically
- **Secure updates** - Code-signed and notarized builds
- **Appcast feeds** - Separate feeds for stable and development channels

---

## Mermaid Diagrams

SAM renders Mermaid diagrams inline in conversations. When the AI generates a Mermaid code block, SAM renders it as a visual diagram. Supports 15 diagram types including flowcharts, sequence diagrams, class diagrams, state diagrams, and more.

---

## Think Tags

When supported models use extended thinking (e.g., Claude's thinking blocks), SAM displays the reasoning process in collapsible sections. You can see the AI's step-by-step reasoning without it cluttering the response.

---

## Logging

SAM uses structured logging via swift-log:

- Log levels: debug, info, warning, error
- Logger labels follow `com.sam.<module>` convention
- Logs accessible via Help > Show Logs
- Useful for troubleshooting and bug reports

---

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘N | New conversation |
| ⌘K | Clear current conversation |
| ⇧⌘R | Rename conversation |
| ⇧⌘D | Duplicate conversation |
| ⇧⌘E | Export conversation |
| ⌘⌫ | Delete conversation |
| ⌘F | Search conversations |
| ⇧⌘/ | Show help |
| ⌘, | Open Settings |
| ⌘W | Close window |
| Enter | Send message |
| Shift+Enter | New line in message |

---

## Version Scheme

SAM uses date-based versioning:

- **Stable:** `YYYYMMDD.RELEASE` (e.g., `20260110.1`)
- **Development:** `YYYYMMDD.RELEASE-dev.BUILD` (e.g., `20260110.1-dev.3`)

See [VERSIONING.md](../VERSIONING.md) for details.
