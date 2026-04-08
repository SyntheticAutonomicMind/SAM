# SAM Technical Documentation

This directory contains comprehensive technical documentation for SAM developers and contributors.

**Last Updated:** April 7, 2026
**License:** CC-BY-NC-4.0

---

## Documentation Index

### Core Architecture

| Document | Description | Lines |
|----------|-------------|-------|
| [API_FRAMEWORK.md](API_FRAMEWORK.md) | Provider system, endpoints, authentication, OpenAI compatibility | 885 |
| [AGENT_ORCHESTRATOR.md](AGENT_ORCHESTRATOR.md) | Agent loop, tool dispatch, streaming, auto-continue | 584 |
| [MCP_TOOLS_SPECIFICATION.md](MCP_TOOLS_SPECIFICATION.md) | Complete tool API reference (8 tools, 60+ operations) | 208 |
| [CONVERSATION_ENGINE.md](CONVERSATION_ENGINE.md) | Chat processing, state management, persistence | 946 |
| [MESSAGING_ARCHITECTURE.md](MESSAGING_ARCHITECTURE.md) | Message flow, transformations, streaming | 1,018 |
| [STREAMING_CONVERSATIONAL_ARCHITECTURE.md](STREAMING_CONVERSATIONAL_ARCHITECTURE.md) | Real-time streaming implementation | 237 |
| [CHAT_INTERFACE_ARCHITECTURE.md](CHAT_INTERFACE_ARCHITECTURE.md) | UI components, ChatWidget, message rendering | 264 |
| [SYSTEM_PROMPT_EVOLUTION.md](SYSTEM_PROMPT_EVOLUTION.md) | System prompt design history and current architecture | 266 |

### Subsystems

| Document | Description | Lines |
|----------|-------------|-------|
| [MLX_INTEGRATION.md](MLX_INTEGRATION.md) | Local model support for Apple Silicon (MLX framework) | 670 |
| [SOUND.md](SOUND.md) | Voice input/output, wake word detection, speech synthesis | 496 |
| [MERMAID_ARCHITECTURE.md](MERMAID_ARCHITECTURE.md) | Diagram rendering (15 diagram types) | 679 |
| [CONFIGURATION_SYSTEM.md](CONFIGURATION_SYSTEM.md) | Settings, preferences, persistence | 749 |
| [SHARED_DATA.md](SHARED_DATA.md) | Cross-conversation data sharing | 424 |
| [CLIO_INTEGRATION.md](CLIO_INTEGRATION.md) | Integration with CLIO terminal AI assistant | 219 |

### Specifications

| Document | Description | Lines |
|----------|-------------|-------|
| [API_INTEGRATION_SPECIFICATION.md](API_INTEGRATION_SPECIFICATION.md) | Provider integration guide, protocol requirements | 964 |
| [API_AUTHENTICATION.md](API_AUTHENTICATION.md) | Authentication flows, Copilot token management | 118 |
| [SECURITY_SPECIFICATION.md](SECURITY_SPECIFICATION.md) | Security model, sandboxing, authorization | 1,222 |
| [MEMORY_AND_INTELLIGENCE_SPECIFICATION.md](MEMORY_AND_INTELLIGENCE_SPECIFICATION.md) | RAG system, vector search, document import | 424 |
| [AUTOMATION_SPECIFICATION.md](AUTOMATION_SPECIFICATION.md) | Autonomous execution, iteration limits | 675 |
| [WEB_RESEARCH_SPECIFICATION.md](WEB_RESEARCH_SPECIFICATION.md) | Web search, scraping, content extraction | 647 |
| [TOOL_CARD_ARCHITECTURE.md](TOOL_CARD_ARCHITECTURE.md) | Tool execution UI, status display | 567 |
| [PLATFORM_INTEGRATION_SPECIFICATION.md](PLATFORM_INTEGRATION_SPECIFICATION.md) | macOS integration, Sparkle updates, permissions | 385 |
| [PROTOCOL_AND_COMMUNICATION_SPECIFICATION.md](PROTOCOL_AND_COMMUNICATION_SPECIFICATION.md) | Message protocols, SSE streaming | 491 |

### Flow Documentation

| Document | Description | Lines |
|----------|-------------|-------|
| [flows/message_flow.md](flows/message_flow.md) | End-to-end message processing from UI to AI and back | 774 |
| [flows/tool_execution_flow.md](flows/tool_execution_flow.md) | Tool invocation, execution, and result handling | 523 |
| [flows/TOOL_EXECUTION_FLOWS.md](flows/TOOL_EXECUTION_FLOWS.md) | Comprehensive tool system flows | 704 |
| [flows/model_loading_flow.md](flows/model_loading_flow.md) | Local model initialization (MLX and GGUF) | 461 |
| [flows/conversation_persistence.md](flows/conversation_persistence.md) | Saving, loading, and managing conversations | 542 |

### Internal/Development

| Document | Description | Lines |
|----------|-------------|-------|
| [MCP_CONSOLIDATION_ARCHITECTURE.md](MCP_CONSOLIDATION_ARCHITECTURE.md) | MCP refactoring notes | 382 |
| [SEQUENTIAL_THINKING_ARCHITECTURE.md](SEQUENTIAL_THINKING_ARCHITECTURE.md) | Sequential thinking implementation notes | 553 |
| [SWIFT6_CONCURRENCY_MIGRATION.md](SWIFT6_CONCURRENCY_MIGRATION.md) | Swift 6 strict concurrency migration guide | 63 |
| [MCP_FRAMEWORK.md](MCP_FRAMEWORK.md) | MCP framework stub (minimal) | 9 |

---

## Documentation Standards

All documentation files follow these standards:

1. **SPDX License Headers:** All files include `CC-BY-NC-4.0` license headers
2. **Last Updated Dates:** Most files include "Last Updated" dates
3. **Markdown Format:** GitHub-flavored Markdown with tables, code blocks, and diagrams
4. **No Sensitive Information:** All files audited for public release

## Recent Updates

### April 7, 2026
- **Full documentation QA pass:** Verified all claims against actual source code
- **Provider accuracy:** Updated all provider lists to include Google Gemini, MiniMax, OpenRouter
- **Tool accuracy:** Fixed tool counts (8 tools), verified operation lists against code
- **Math formulas:** Expanded formula list from 10 to 24 (matching actual implementation)
- **Storage paths:** Corrected model cache path (`sam-rewritten/models/`), verified `memory.db` paths
- **Keyboard shortcuts:** Expanded shortcuts table with all documented commands
- **Cross-doc consistency:** Ensured provider lists, tool names, and paths match across all docs

### March 12, 2026
- **Documentation overhaul:** Removed stale docs for deleted features (StableDiffusion, Training/LoRA, Think tool, Python validation)
- **Deleted:** STABLE_DIFFUSION.md, LORA_TRAINING.md, DOCUMENT_TRAINING_EXPORT.md, PYTHON_VALIDATION.md, THINK_TOOL_SPECIFICATION.md
- **Deleted flows:** sd_generation_flow.md, lora_training_flow.md, document_training_export_flow.md
- **Deleted handoffs:** HANDOFF_2025-12-17_PDF_TABLES.md, PDF_EXPORT_SESSION_2025-12-16.md
- **Updated all docs:** Replaced stale SD/Training/subagent/workflow-mode references with current tools (ALICE, math_operations)
- **Added to index:** AGENT_ORCHESTRATOR.md, API_AUTHENTICATION.md, CLIO_INTEGRATION.md, SYSTEM_PROMPT_EVOLUTION.md, SWIFT6_CONCURRENCY_MIGRATION.md

### December 11, 2025
- **Full documentation audit:** All files reviewed and approved for SAM 1.0 release

## Audit Status

**Current:** 27 documentation files (+ this README), ~13,500 lines of technical documentation

- License compliance: 100% (all have SPDX headers)
- Sensitive information: None found
- Last full audit: April 7, 2026

---

## Usage Guidelines

### For Contributors
- Read relevant architecture docs before making changes
- Update documentation when changing system behavior
- Follow existing naming patterns (UPPERCASE_WITH_UNDERSCORES.md)
- Include SPDX headers and "Last Updated" dates

### For Developers
- Read core architecture docs for system overview
- Check flow documentation for implementation details
- Refer to specifications for API contracts

### For AI Collaboration
- These docs are optimized for AI context consumption
- Use semantic search to find relevant sections
- Architecture docs explain "how it works"
- Specifications explain "how to use it"
- Flow docs explain "how it flows"

---

## Contributing to Documentation

Documentation improvements are welcome! Please:

1. Match existing format and style
2. Include code examples where helpful
3. Update "Last Updated" date
4. Verify links work
5. Keep line lengths reasonable (<120 chars)
6. Test Markdown rendering

See [CONTRIBUTING.md](../CONTRIBUTING.md) for general contribution guidelines.

---

**Questions?** Open an issue or discussion on GitHub.
