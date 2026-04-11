# SAM Documentation

User-facing documentation for SAM (Synthetic Autonomic Mind).

For deeper implementation notes and internal specifications, see [`project-docs/`](../project-docs/).

---

## Getting Started

| Document | What it covers |
|----------|----------------|
| [Installation](INSTALLATION.md) | Installing SAM, first launch, updates, and uninstalling |
| [User Guide](USER_GUIDE.md) | Day-to-day use, setup, conversations, tools, and workflows |
| [Providers](PROVIDERS.md) | Cloud and local model configuration |

## Core Reference

| Document | What it covers |
|----------|----------------|
| [Features](FEATURES.md) | Product capabilities and current feature set |
| [Tools](TOOLS.md) | SAM's built-in tool system and operations |
| [Memory](MEMORY.md) | Conversation memory, semantic search, documents, and long-term memory |
| [Performance](PERFORMANCE.md) | Resource usage, local model expectations, and optimization tips |
| [Security](SECURITY.md) | Privacy model, key storage, API server security, and file authorization |

## Technical Overview

| Document | What it covers |
|----------|----------------|
| [Architecture](ARCHITECTURE.md) | High-level system design and module layout |

## Developer Docs

| Document | What it covers |
|----------|----------------|
| [Building from Source](../BUILDING.md) | Build and development workflow |
| [Contributing](../CONTRIBUTING.md) | How to contribute to SAM |
| [Versioning](../VERSIONING.md) | Release and versioning scheme |
| [Release Notes](../RELEASE_NOTES.md) | Release-note generation workflow |
| [Internal Specs](../project-docs/) | Detailed architecture and subsystem specifications |

---

## Current Product Shape

SAM is a native macOS AI assistant with:

- Native SwiftUI interface
- Support for local and cloud AI providers
- Built-in tools for files, web research, documents, math, and macOS integration
- Per-conversation memory plus long-term memory features
- Voice input and speech output
- Remote access through SAM-Web and the local API server
- Privacy-first defaults with user-controlled integrations
