# SAM Features

Current feature reference for SAM (Synthetic Autonomic Mind).

---

## Overview

SAM is a native macOS AI assistant built with Swift and SwiftUI. It combines conversation, memory, tools, local-model support, macOS integration, voice, and remote access in one application.

This document describes the product as it exists now, not as a wish list.

---

## Core Experience

### Native macOS app

SAM is a native application, not a browser shell. It uses SwiftUI and AppKit-backed platform features where appropriate.

### Conversation-based interface

- Multiple saved conversations
- Automatic persistence
- Conversation export and import
- Per-conversation state and settings
- Model switching within a conversation
- Shared Topics for project-based continuity across multiple conversations

### Personalization

- Personality support for changing SAM's response style and behavior profile
- Mini-prompts for reusable, workflow-specific instruction sets
- Per-conversation customization layered on top of the core system prompt flow

### Autonomous task execution

SAM can use tools to carry out multi-step work, inspect results, and continue the task flow.

---

## AI Provider Support

### Cloud providers

SAM currently supports:

- **OpenAI**
- **GitHub Copilot**
- **DeepSeek**
- **Google Gemini**
- **MiniMax**
- **OpenRouter**
- **Custom OpenAI-compatible endpoints**

### Local providers

- **MLX** on Apple Silicon
- **llama.cpp** for GGUF-based local models

### Notes on model access

- Claude-family access may be available through **GitHub Copilot** or **OpenRouter**
- There is no direct Anthropic provider in the current codebase
- Local and cloud providers can coexist in the same setup

---

## Memory and Context

### Conversation memory

SAM preserves and manages conversation history automatically.

### Semantic search

You can search prior conversations and imported content by meaning, not only keyword match.

### Long-term memory

SAM includes longer-lived memory capabilities for:

- discoveries
- problem/solution pairs
- reusable patterns
- per-conversation working notes

### Shared Topics

Shared Topics let related conversations share project context more effectively while still keeping message histories separate.

This is especially useful for:

- long-running projects
- research work split across conversations
- ongoing technical investigations
- multi-session task continuity

### Context management

Long conversations are trimmed and archived intelligently so useful context can still be recalled when needed.

---

## Document Workflows

### Document import

SAM can import documents into conversation memory for retrieval and question answering.

### Document creation

Current document creation support includes:

- PDF
- DOCX
- TXT
- Markdown
- PPTX
- RTF
- XLSX

### Export and reporting

SAM can generate formatted artifacts and conversation exports suitable for sharing or archiving.

Conversation export supports practical handoff and archival workflows in addition to document generation.

---

## Web and Research

### Web search and retrieval

SAM supports:

- fast web search
- URL fetching
- structured scraping
- deeper multi-source research
- retrieval of previously stored research

### SerpAPI-enhanced workflows

When SerpAPI is configured, SAM can use domain-specific search engines for shopping, travel, restaurants, and similar tasks.

---

## File and Code Workflows

SAM can help with:

- reading files
- searching code and content
- creating and modifying files
- inspecting file metadata
- checking errors on supported file types
- symbol usage search

Its file tools are bounded by workspace and authorization rules.

---

## macOS Integration

SAM includes native integrations for:

- **Calendar and Reminders**
- **Contacts**
- **Apple Notes**
- **Spotlight search**
- **Weather**

These features are exposed through explicit tool operations rather than hidden background behavior.

---

## Voice Features

SAM includes voice support for conversational interaction.

### Input
- Wake word support
- Speech recognition
- Hands-free interaction

### Output
- Text-to-speech responses
- Streaming speech output
- Configurable voices and devices

---

## Image Generation

SAM can connect to an **ALICE** server for remote image generation.

### Current capabilities
- Model listing
- Prompt-based image generation
- Generated image download into the local environment

This feature depends on ALICE being configured and reachable.

---

## Remote Access

### SAM-Web support

SAM can expose a local API server so you can connect through SAM-Web from a browser on another device.

### API server features
- Token-based authentication
- Local-network use
- Browser-based access to conversations and core features

---

## Workflow and Usability Features

### Import and export

SAM supports exporting conversation data for sharing, archiving, and handoff workflows. It also supports importing prior conversation data back into the app.

### Help and discoverability

SAM includes built-in help content and keyboard-driven navigation support for common actions.

### Keyboard-driven workflow support

The interface includes keyboard shortcuts for conversation creation, search, export, help, preferences, and other common actions.

---

## Privacy and Security Features

### Local-first design
- Conversations stored locally
- No telemetry
- Local model support
- Cloud use is optional

### Secret handling
- Provider credentials stored in Keychain
- Secret redaction for sensitive content headed to cloud providers

### File authorization
- Working-directory operations are auto-approved
- Access outside the workspace requires authorization

---

## Performance Features

### Apple Silicon optimization
- MLX support
- Native architecture
- Local model lifecycle management

### Context and memory efficiency
- Archived context retrieval
- Searchable embeddings
- Dynamic context handling by model capability

---

## What SAM Is Good At

SAM is especially well suited for:

- day-to-day Mac productivity
- research and synthesis
- project-oriented conversation workflows
- private/local AI usage
- document-assisted conversations
- mixed local/cloud model setups
- tool-assisted task execution

---

## See Also

- [User Guide](USER_GUIDE.md)
- [Tools](TOOLS.md)
- [Providers](PROVIDERS.md)
- [Memory](MEMORY.md)
- [Architecture](ARCHITECTURE.md)
