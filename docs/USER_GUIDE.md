# SAM User Guide

Complete guide to using SAM.

---

## Table of Contents

1. [Getting Started](#getting-started)
2. [Conversations](#conversations)
3. [Providers](#providers)
4. [Tools and Actions](#tools-and-actions)
5. [Memory and Documents](#memory-and-documents)
6. [Personalities and Mini-Prompts](#personalities-and-mini-prompts)
7. [Voice Features](#voice-features)
8. [macOS Integrations](#macos-integrations)
9. [Remote Access](#remote-access)
10. [Privacy and Control](#privacy-and-control)
11. [Keyboard Shortcuts](#keyboard-shortcuts)
12. [Tips](#tips)
13. [Troubleshooting](#troubleshooting)

---

## Getting Started

SAM is a native macOS AI assistant designed to be useful in real workflows, not just one-off prompts.

After installing the app:

1. Open **Settings**
2. Add at least one AI provider
3. Start a new conversation
4. Ask naturally for what you want done

For installation details, see [INSTALLATION.md](INSTALLATION.md).

---

## Conversations

### Multiple saved conversations

SAM supports multiple conversations, each with its own history and working context.

### Automatic saving

Conversations are saved automatically as you work.

### Per-conversation state

A conversation can carry its own:
- history
- working directory
- model selection
- tool activity
- associated memory state

### Model switching

You can switch models mid-conversation without throwing away the conversation itself.

### Import and export

SAM supports conversation export for sharing, archiving, and handoff workflows.

Current export paths in the app include:
- JSON export
- Markdown export
- PDF export for conversation-oriented output flows

Conversation import is also supported, which makes it easier to bring prior sessions back into SAM.

### Shared Topics

If you have several conversations that belong to the same project, Shared Topics help keep them connected.

Shared Topics are useful when you want:
- a shared workspace
- better continuity across multiple conversations
- project-oriented context instead of one huge chat

---

## Providers

SAM supports these provider types today:

- OpenAI
- GitHub Copilot
- DeepSeek
- Google Gemini
- MiniMax
- OpenRouter
- Local MLX
- Local llama.cpp
- Custom OpenAI-compatible endpoints

### Important note about Claude

If you want Claude-family access, that generally comes through providers like GitHub Copilot or OpenRouter rather than a direct Anthropic integration.

For setup details, see [PROVIDERS.md](PROVIDERS.md).

---

## Tools and Actions

One of SAM's defining features is that it can use tools to act on your behalf.

### Current built-in tool categories

- collaboration and approvals
- memory and task tracking
- web and research
- documents
- files
- math and computation
- image generation
- calendar and reminders
- contacts
- notes
- Spotlight search
- weather

### What this means in practice

SAM can help with workflows like:
- searching for files and reading them
- gathering web research and summarizing it
- importing and generating documents
- doing exact calculations
- updating reminders or events
- looking up contacts or notes
- checking weather
- creating structured task lists for multi-step work

### Progress tracking

For multi-step work, SAM uses a visible todo system so you can see what it is doing.

### Practical examples

Examples of tool-assisted workflows include:
- importing a document, asking questions about it, and exporting the result
- searching the web, fetching supporting pages, and summarizing findings
- updating reminders or notes while continuing the same conversation
- working through a multi-step task with visible todo progress

---

## Memory and Documents

### Conversation memory

SAM uses conversation history as working context and can search prior content semantically.

### Working memory and long-term memory

SAM supports:
- temporary working notes
- history recall after context trimming
- longer-term discoveries, solutions, and patterns

### Document workflows

SAM can import documents into a conversation and use them as part of retrieval-aware assistance.

Current document creation formats include:
- PDF
- DOCX
- TXT
- Markdown
- PPTX
- RTF
- XLSX

In practice, this means you can:
- bring a document into the conversation for analysis
- ask follow-up questions against imported content
- create new formatted outputs based on what you learned
- export the resulting conversation or deliverable for sharing

---

## Personalities and Mini-Prompts

SAM supports both personalities and mini-prompts.

### Personalities

Personalities let you change how SAM presents itself and responds. They are useful when you want a different tone, perspective, or working style for a conversation.

### Mini-prompts

Mini-prompts are reusable instruction sets that can be applied to steer a conversation or workflow without rewriting the same guidance every time.

These are useful for:
- recurring task patterns
- domain-specific workflows
- preferred answer structures
- repeated setup instructions

---

## Voice Features

SAM includes voice support for people who prefer hands-free interaction.

### Input
- wake word support
- speech recognition
- spoken prompts

### Output
- text-to-speech
- spoken responses
- configurable voices and playback behavior

Voice features are optional and can be enabled or disabled in Settings.

---

## macOS Integrations

SAM includes built-in integration tools for:

### Calendar and Reminders
- list events
- create events
- search events
- manage reminders

### Contacts
- search contacts
- inspect contact details
- create and update contacts

### Apple Notes
- search notes
- read notes
- create notes
- append to notes

### Spotlight
- search files and content
- inspect metadata
- find recent files

### Weather
- current weather
- forecast
- hourly outlook

These integrations are tool-driven and visible in the interface.

---

## Remote Access

SAM can expose a local API server for use with SAM-Web.

### Typical remote workflow

1. Enable the API server in Settings
2. Copy the API token
3. Connect through SAM-Web from another device on your network

This gives you browser-based access to SAM while the native app continues running on your Mac.

---

## Privacy and Control

SAM is designed to give you useful autonomy without hiding what it is doing.

### You stay in control through:
- visible tool cards
- authorization requirements for sensitive file access
- optional cloud-provider usage
- local-model support
- Keychain-backed credential storage
- preferences-controlled features

### Working directory boundaries

SAM generally has automatic access within its workspace and needs authorization for access outside that workspace.

---

## Keyboard Shortcuts

SAM includes keyboard shortcuts for common actions. The built-in help also surfaces them in the UI.

Common shortcuts include:

- `N` - New conversation
- `K` - Clear current conversation
- `⇧R` - Rename conversation
- `⇧D` - Duplicate conversation
- `⇧E` - Export conversation
- `F` - Search conversations
- `⇧/` - Show help
- `,` - Open Preferences
- `W` - Close window

---

## Tips

### Use focused conversations

If you start a completely different task, a fresh conversation often works better.

### Let the tools do the work

You usually get the best results by telling SAM the outcome you want rather than trying to script every step manually.

### Use local models when privacy matters most

For sensitive work, local models help keep the workflow on your own machine.

### Use cloud models when reach matters more

For larger hosted model catalogs or specialized capabilities, cloud providers are a good complement.

---

## Troubleshooting

### SAM is not responding

Check that at least one provider is configured and enabled.

### A tool is unavailable

Some tools depend on service availability or platform permissions. For example:
- image generation requires ALICE
- some macOS integrations may need permission prompts approved
- remote access requires the API server to be enabled

### A provider works inconsistently

Verify:
- API key or sign-in state
- base URL if using a custom provider
- selected model availability

### A file action is blocked

That usually means the requested path is outside the current working directory and needs authorization.

---

## See Also

- [Installation](INSTALLATION.md)
- [Providers](PROVIDERS.md)
- [Tools](TOOLS.md)
- [Memory](MEMORY.md)
- [Security](SECURITY.md)
