# SAM Technical Documentation

This directory contains comprehensive technical documentation for SAM developers and contributors.

**Last Updated:** December 11, 2025  
**License:** CC-BY-NC-4.0

---

## Documentation Index

### Methodology

| Document | Description | Lines |
|----------|-------------|-------|
| [THE_UNBROKEN_METHOD.md](THE_UNBROKEN_METHOD.md) | Complete AI collaboration framework - 7 pillars for successful human-AI development | 1,001 |

### Core Architecture

| Document | Description | Lines |
|----------|-------------|-------|
| [API_FRAMEWORK.md](API_FRAMEWORK.md) | Provider system, endpoints, authentication, OpenAI compatibility | 783 |
| [MCP_FRAMEWORK.md](MCP_FRAMEWORK.md) | Model Context Protocol implementation, tool system, execution | 1,910 |
| [CONVERSATION_ENGINE.md](CONVERSATION_ENGINE.md) | Chat processing, state management, persistence | 1,003 |
| [MESSAGING_ARCHITECTURE.md](MESSAGING_ARCHITECTURE.md) | Message flow, transformations, streaming | 1,173 |
| [STREAMING_CONVERSATIONAL_ARCHITECTURE.md](STREAMING_CONVERSATIONAL_ARCHITECTURE.md) | Real-time streaming implementation | 137 |
| [CHAT_INTERFACE_ARCHITECTURE.md](CHAT_INTERFACE_ARCHITECTURE.md) | UI components, ChatWidget, message rendering | 208 |

### Subsystems

| Document | Description | Lines |
|----------|-------------|-------|
| [STABLE_DIFFUSION.md](STABLE_DIFFUSION.md) | Image generation, model types, schedulers, MPS optimizations | 914 |
| [MLX_INTEGRATION.md](MLX_INTEGRATION.md) | Local model support for Apple Silicon (MLX framework) | 677 |
| [SOUND.md](SOUND.md) | Voice input/output, wake word detection, speech synthesis | 534 |
| [MERMAID_ARCHITECTURE.md](MERMAID_ARCHITECTURE.md) | Diagram rendering (15 diagram types) | 788 |
| [CONFIGURATION_SYSTEM.md](CONFIGURATION_SYSTEM.md) | Settings, preferences, persistence | 637 |
| [SHARED_DATA.md](SHARED_DATA.md) | Cross-conversation data sharing | 424 |
| [PYTHON_VALIDATION.md](PYTHON_VALIDATION.md) | Python bundle validation system for CI/CD builds | 244 |

### Specifications

| Document | Description | Lines |
|----------|-------------|-------|
| [MCP_TOOLS_SPECIFICATION.md](MCP_TOOLS_SPECIFICATION.md) | Complete tool API reference (14 tools, 46+ operations) | 598 |
| [API_INTEGRATION_SPECIFICATION.md](API_INTEGRATION_SPECIFICATION.md) | Provider integration guide, protocol requirements | 964 |
| [SECURITY_SPECIFICATION.md](SECURITY_SPECIFICATION.md) | Security model, sandboxing, authorization | 1,222 |
| [MEMORY_AND_INTELLIGENCE_SPECIFICATION.md](MEMORY_AND_INTELLIGENCE_SPECIFICATION.md) | RAG system, vector search, document import | 358 |
| [AUTOMATION_SPECIFICATION.md](AUTOMATION_SPECIFICATION.md) | Autonomous execution, subagents, iteration limits | 675 |
| [WEB_RESEARCH_SPECIFICATION.md](WEB_RESEARCH_SPECIFICATION.md) | Web search, scraping, content extraction | 688 |
| [THINK_TOOL_SPECIFICATION.md](THINK_TOOL_SPECIFICATION.md) | Internal reasoning and planning tool | 444 |
| [TOOL_CARD_ARCHITECTURE.md](TOOL_CARD_ARCHITECTURE.md) | Tool execution UI, status display | 656 |
| [PLATFORM_INTEGRATION_SPECIFICATION.md](PLATFORM_INTEGRATION_SPECIFICATION.md) | macOS integration, Sparkle updates, permissions | 385 |
| [PROTOCOL_AND_COMMUNICATION_SPECIFICATION.md](PROTOCOL_AND_COMMUNICATION_SPECIFICATION.md) | Message protocols, SSE streaming | 491 |

### Flow Documentation

| Document | Description | Lines |
|----------|-------------|-------|
| [flows/message_flow.md](flows/message_flow.md) | End-to-end message processing from UI to AI and back | 774 |
| [flows/tool_execution_flow.md](flows/tool_execution_flow.md) | Tool invocation, execution, and result handling | 523 |
| [flows/TOOL_EXECUTION_FLOWS.md](flows/TOOL_EXECUTION_FLOWS.md) | Comprehensive tool system flows | 704 |
| [flows/sd_generation_flow.md](flows/sd_generation_flow.md) | Image generation pipeline (CoreML & Python) | 525 |
| [flows/model_loading_flow.md](flows/model_loading_flow.md) | Local model initialization (MLX & GGUF) | 386 |
| [flows/conversation_persistence.md](flows/conversation_persistence.md) | Saving, loading, and managing conversations | 542 |

### Internal/Development

| Document | Description | Lines |
|----------|-------------|-------|
| [MCP_CONSOLIDATION_ARCHITECTURE.md](MCP_CONSOLIDATION_ARCHITECTURE.md) | MCP refactoring notes | 508 |
| [SEQUENTIAL_THINKING_ARCHITECTURE.md](SEQUENTIAL_THINKING_ARCHITECTURE.md) | Sequential thinking implementation notes | 497 |

---

## Documentation Standards

All documentation files follow these standards:

1. **SPDX License Headers:** All files include `CC-BY-NC-4.0` license headers
2. **Last Updated Dates:** Most files include "Last Updated" dates (some older files may not)
3. **Markdown Format:** GitHub-flavored Markdown with tables, code blocks, and diagrams
4. **No Sensitive Information:** All files audited for public release (see audit summary below)

## Recent Updates

### December 11, 2025
- **STABLE_DIFFUSION.md:** Updated with SDXL float32 conversion, MPS limitations, SDE scheduler removal
- **Session handoffs:** Moved to `.gitignore` (development-only, not for public release)
- **Full documentation audit:** All 30 files reviewed and approved for SAM 1.0 release

## Audit Status

✅ **Approved for SAM 1.0 Public Release**

- Total files: 30 documentation files
- Total lines: 19,845 lines of technical documentation
- License compliance: 100% (all have SPDX headers)
- Sensitive information: None found
- Audit date: December 11, 2025

See `scratch/AUDIT_SUMMARY.md` for detailed audit report (development directory, not in repository).

---

## Usage Guidelines

### For Contributors
- Read relevant architecture docs before making changes
- Update documentation when changing system behavior
- Follow existing naming patterns (UPPERCASE_WITH_UNDERSCORES.md)
- Include SPDX headers and "Last Updated" dates

### For Developers
- Start with [THE_UNBROKEN_METHOD.md](THE_UNBROKEN_METHOD.md) to understand development philosophy
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
