# SAM - Synthetic Autonomic Mind

**A native macOS AI assistant that remembers, gets work done, and keeps you in control.**

Built for macOS. Built for privacy. Built for real workflows.

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Platform](https://img.shields.io/badge/platform-macOS%2014.0%2B-lightgrey.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/swift-6.0%2B-orange.svg)](https://swift.org/)

[Website](https://www.syntheticautonomicmind.org) | [Download](https://github.com/SyntheticAutonomicMind/SAM/releases) | [Documentation](docs/README.md)

---

## What SAM Is

SAM is a native macOS AI assistant built with Swift and SwiftUI. It combines conversation, memory, tools, local-model support, voice, and macOS integrations in one application.

SAM is designed for people who want AI to be useful in real workflows - not just a chat box. It can help with research, organization, documents, local or cloud inference, and structured task execution while keeping your data under your control.

---

## Why SAM Exists

SAM started with a simple goal: build the AI assistant my wife actually wanted to use.

The idea was not to make people adapt themselves to an AI product. The idea was to build an assistant that adapts to the person using it - one that feels native on the Mac, respects privacy, and helps with real work instead of just producing chat responses.

What began as something personal grew into a full native macOS assistant for conversation, memory, research, documents, tools, voice, and project-oriented workflows.

Like most of my software, SAM is available as Open Source with the hope that it is as useful to others as it is to us.

---

## Why People Use SAM

### Native macOS experience

SAM is built specifically for macOS instead of being treated like a generic cross-platform wrapper.

### Real tool use

SAM can use tools for files, web research, documents, math, and system integrations rather than stopping at text responses.

### Local-first privacy

You can use local models, keep conversations on your Mac, and choose cloud providers only when you want them.

### Memory and continuity

SAM supports semantic memory search, archived context recall, long-term memory patterns, and project-oriented workflows.

### Flexible providers

You can use:
- OpenAI
- GitHub Copilot
- DeepSeek
- Google Gemini
- MiniMax
- OpenRouter
- Local MLX
- Local llama.cpp
- Custom OpenAI-compatible endpoints

> Note: SAM does not currently ship a direct Anthropic provider. Claude-family models may be available through GitHub Copilot or OpenRouter depending on those services.

---

## Major Capabilities

### Conversations and memory
- Multiple saved conversations
- Automatic persistence
- Conversation export in JSON and Markdown
- Semantic search across conversation content
- Archived context recall for long-running sessions
- Long-term memory features for discoveries, solutions, and patterns
- Shared Topics for project-oriented continuity across related conversations

### Tool-assisted workflows
- File operations
- Web research and content retrieval
- Document import and creation
- Exact math and formula execution
- Structured todo tracking for multi-step tasks
- Collaboration checkpoints when user input is needed
- Conversation and document export workflows for sharing and archiving

### macOS integrations
- Calendar and Reminders
- Contacts
- Apple Notes
- Spotlight search
- Weather

### Local and remote AI options
- MLX on Apple Silicon
- llama.cpp for GGUF models
- cloud providers when you want them
- SAM-Web support via the local API server

### Voice and media
- Wake word and speech input
- Text-to-speech responses
- ALICE-based remote image generation when configured

### Personalization and workflow helpers
- Personality support for different response styles and task modes
- Mini-prompts for reusable instruction sets and workflow shortcuts
- Built-in help and keyboard navigation for faster daily use

---

## Current Tool Surface

SAM's built-in tool system currently includes:

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

This tool system is how SAM turns requests into concrete actions.

---

## Install SAM

### Homebrew

```bash
brew tap SyntheticAutonomicMind/homebrew-SAM
brew install --cask sam
```

### Direct download

Download the latest release from:

https://github.com/SyntheticAutonomicMind/SAM/releases

---

## Quick Start

1. Install SAM
2. Open **Settings > AI Providers**
3. Add a provider
4. Start a conversation
5. Ask naturally for what you want done

If you want the most private setup, start with a local MLX or llama.cpp model.
If you want broader hosted model access, add one or more cloud providers.

---

## A Few Practical Examples

- Ask SAM to research a topic, fetch the sources, and summarize the result
- Import a document, ask follow-up questions about it, then export the conversation
- Use Shared Topics to keep several related conversations tied to one project workspace
- Switch between personalities or mini-prompts depending on the kind of work you are doing
- Use calendar, reminders, notes, contacts, Spotlight, and weather tools from the same conversation

---

## Documentation

User-facing documentation lives in [`docs/`](docs/):

- [Installation Guide](docs/INSTALLATION.md)
- [User Guide](docs/USER_GUIDE.md)
- [Providers Guide](docs/PROVIDERS.md)
- [Tools Reference](docs/TOOLS.md)
- [Memory Guide](docs/MEMORY.md)
- [Security Guide](docs/SECURITY.md)
- [Architecture Overview](docs/ARCHITECTURE.md)

Developer and deeper architecture docs live in [`project-docs/`](project-docs/).

---

## Build from Source

```bash
git clone --recursive https://github.com/SyntheticAutonomicMind/SAM.git
cd SAM
make build-debug
```

For full build details, see [BUILDING.md](BUILDING.md).

---

## Privacy and Security

SAM is designed around a local-first model:

- conversations and app state stay on your Mac
- provider credentials are stored in Keychain
- local models are supported directly
- file access follows workspace and authorization rules
- cloud use is optional
- telemetry is not part of the product model

For details, see [docs/SECURITY.md](docs/SECURITY.md).

---

## Part of the Synthetic Autonomic Mind Ecosystem

SAM works alongside other open projects in the ecosystem:

- [CLIO](https://github.com/SyntheticAutonomicMind/CLIO) - AI terminal agent
- [MIRA](https://github.com/SyntheticAutonomicMind/MIRA) - graphical terminal for CLIO
- [ALICE](https://github.com/SyntheticAutonomicMind/ALICE) - remote image generation server
- [SAM-Web](https://github.com/SyntheticAutonomicMind/SAM-web) - browser-based interface for SAM

---

## Contributing

If you want to contribute, start here:

- [CONTRIBUTING.md](CONTRIBUTING.md)
- [AGENTS.md](AGENTS.md)
- [BUILDING.md](BUILDING.md)

---

## License

SAM is licensed under GPL-3.0-only.
