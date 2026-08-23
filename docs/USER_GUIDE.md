# SAM User Guide

**Complete guide to using SAM (Synthetic Autonomic Mind)**

---

## Table of Contents

1. [Introduction](#introduction)
2. [Getting Started](#getting-started)
3. [Conversations](#conversations)
4. [AI Providers](#ai-providers)
5. [Voice Control](#voice-control)
6. [Tools and Autonomous Actions](#tools-and-autonomous-actions)
7. [Memory and Search](#memory-and-search)
8. [Documents](#documents)
9. [Image Generation (ALICE)](#image-generation-alice)
10. [Math and Calculations](#math-and-calculations)
11. [SAM-Web: Remote Access](#sam-web-remote-access)
12. [Shared Topics](#shared-topics)
13. [Personality System](#personality-system)
14. [Preferences and Settings](#preferences-and-settings)
15. [Keyboard Shortcuts](#keyboard-shortcuts)
16. [Tips and Best Practices](#tips-and-best-practices)
17. [Troubleshooting](#troubleshooting)
18. [FAQ](#faq)

---

## Introduction

### What is SAM?

SAM is a native macOS AI assistant that lives on your Mac. It's built with Swift and SwiftUI, runs natively on Apple Silicon and Intel Macs, and keeps all your data local. SAM connects to AI providers (cloud or local) to help you with writing, research, file management, image generation, math, and much more - all through natural conversation.

SAM was designed for everyday users, not just developers. You don't need technical skills to use it. Just type or speak, and SAM handles the rest.

### What Makes SAM Different?

**Privacy First** - Your conversations, documents, and memories stay on your Mac. Nothing is sent to the cloud unless you explicitly choose a cloud AI provider, and even then, only the minimum context needed for the AI to respond.

**Real Assistance** - SAM doesn't just answer questions. It can read and write files, search the web, create documents, generate images, do real math, and execute multi-step tasks autonomously.

**Smart Memory** - SAM remembers what matters across conversations. Import documents and ask questions about them. Search your conversation history by meaning, not just keywords.

**Hands-Free** - Say "Hey SAM" to activate voice control. Have a full conversation without touching the keyboard.

---

## Getting Started

### Installation

**Using Homebrew (Recommended)**

```bash
brew tap SyntheticAutonomicMind/homebrew-SAM
brew install --cask sam
```

To update later:
```bash
brew upgrade --cask sam
```

**Manual Download**

1. Download the latest release from [GitHub Releases](https://github.com/SyntheticAutonomicMind/SAM/releases)
2. Open the DMG and drag SAM to your Applications folder
3. First launch: Right-click SAM.app and select Open (macOS Gatekeeper requirement, only needed once)

### First Launch

When you open SAM for the first time:

1. **Set up an AI provider** - Open Settings (`,`) and go to the AI Providers tab
2. **Choose your provider:**
   - **Cloud AI** - OpenAI, GitHub Copilot, DeepSeek, Google Gemini, MiniMax, OpenRouter, Ollama Cloud, Z.AI (Chat), Z.AI (Coding)
   - **Local AI** - Download and run a model directly on your Mac (Apple Silicon recommended for MLX/CachyLLama)
3. **Enter your API key** (for cloud providers)
4. **Start chatting** - Press N for a new conversation, type your message, and press Enter

### System Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon (M1/M2/M3/M4) recommended for local models
- Intel Macs supported (cloud providers and llama.cpp local models)
- 8GB RAM minimum, 16GB+ recommended for local models

---

## Conversations

### Creating and Managing Conversations

- **New conversation** - Press N or click the + button in the sidebar
- **Switch conversations** - Click any conversation in the sidebar
- **Rename** - Double-click a conversation title in the sidebar, or right-click and choose Rename
- **Delete** - Right-click a conversation and choose Delete
- **Export** - Right-click a conversation and choose Export (JSON or Markdown)

### How Conversations Work

Each conversation maintains its own context - the AI remembers everything discussed within that conversation. Conversations are saved automatically as you chat, so you can close SAM and pick up exactly where you left off.

By default, conversations are isolated from each other. The AI in one conversation doesn't know what was said in another. If you want to share context between conversations, use [Shared Topics](#shared-topics).

### Working Directories

Every conversation gets its own working directory at `~/SAM/conversation-{number}/`. When SAM creates files, downloads content, or saves research, it goes into this directory by default. This keeps your work organized and prevents conversations from overwriting each other's files.

For Shared Topics, the working directory is `~/SAM/{topic-name}/` instead, so all conversations in that topic share the same workspace.

### Switching Models Mid-Conversation

You can change AI models at any point during a conversation. Open the model selector in the toolbar and pick a different model. The conversation history carries forward - the new model picks up where the old one left off.

This is useful for starting a task with a fast, inexpensive model and switching to a more capable one when you need deeper reasoning.

---

## AI Providers

SAM supports multiple AI providers. You can configure one or many and switch between them freely.

### Cloud Providers

| Provider | Models | Notes |
|----------|--------|-------|
| **OpenAI** | GPT-4o, GPT-4, GPT-3.5, o1, o3 | Most popular, broad capabilities |
| **Anthropic** | Via OpenRouter | Claude models available through OpenRouter |
| **GitHub Copilot** | GPT-4o, Claude 3.5, o1 | Requires GitHub Copilot subscription |
| **DeepSeek** | DeepSeek Chat, DeepSeek Coder | Cost-effective, good for coding |
| **Google Gemini** | Gemini 2.5 Pro/Flash, 2.0 Flash | Large context (up to 1M tokens) |
| **MiniMax** | MiniMax-M3, M3-highspeed, M2.7 | 128K context, competitive pricing |
| **OpenRouter** | 100+ models | Access many providers through one API |
| **Ollama Cloud** | Various Ollama models | Cloud-hosted, no local server needed |
| **Z.AI (Chat)** | GLM-5.1, GLM-4.9 | Bilingual Chinese/English |
| **Z.AI (Coding)** | GLM-5.1, GLM-4.9 | Specialized for coding |

### Local Models

Run AI completely on your Mac with no internet connection required:

| Engine | Best For | Requirements |
|--------|----------|-------------|
| **MLX** | Apple Silicon Macs, quality | M1+ chip, 8GB+ RAM |
| **CachyLLama** | Apple Silicon Macs, speed | M1+ chip, 8GB+ RAM |
| **llama.cpp** | Any Mac (Intel or Apple Silicon) | 8GB+ RAM |

Local models are downloaded once and run entirely offline. SAM includes a model browser in Settings where you can discover, download, and manage local models.

### Setting Up a Provider

1. Open Settings (`,`)
2. Go to **AI Providers**
3. Click **Add Provider**
4. Select your provider type
5. Enter your API key (cloud providers) or choose a model to download (local)
6. Click Save

### Custom Endpoints

SAM supports any OpenAI-compatible API. If you run a local server (like Ollama, LM Studio, or text-generation-webui), you can connect SAM to it:

1. Add a new provider
2. Choose "Custom OpenAI-Compatible"
3. Enter the endpoint URL (e.g., `http://localhost:11434/v1`)
4. Configure authentication if needed

For detailed provider setup instructions, see [docs/PROVIDERS.md](PROVIDERS.md).

---

## Voice Control

### Wake Word

Say **"Hey SAM"** to activate voice input without touching your Mac. SAM listens for the wake word in the background and starts capturing your voice when it hears it.

**Requirements:**
- Microphone access (SAM will ask on first use)
- Wake word enabled in Settings > Voice

### Speaking to SAM

Once voice input is active:
1. Speak your message naturally
2. SAM transcribes your speech in real time using Apple's on-device speech recognition
3. When you pause, SAM processes your message and responds

### SAM Speaking Back

Enable text-to-speech in Settings > Voice to have SAM read its responses aloud. You can:

- **Choose a voice** - Select from any macOS system voice
- **Adjust speed** - Set speaking rate from 0.5x to 1.5x
- **Select audio devices** - Choose specific input and output devices
- **Test the voice** - Preview your selected voice and rate

### Streaming TTS

SAM starts speaking as soon as the first sentence is ready - it doesn't wait for the entire response to be generated. This makes conversations feel natural and responsive.

### Conversation/Relay Mode

Enable relay mode in Settings > Voice for extended hands-free sessions:
- **Configurable timeout** - How long to wait for continued speech
- **Natural flow** - No need to re-say "Hey SAM" for follow-up

---

## Tools and Autonomous Actions

SAM isn't just a chatbot. It has real tools that let it interact with your Mac, the web, and external services. When you ask SAM to do something, it figures out which tools to use and executes them autonomously.

### What Tools Can Do

**File Operations**
- Read, write, create, and delete files
- Search files by name or content
- Organize files and folders

**Web Research**
- Search the web using Google, Bing, and other engines
- Fetch and analyze web pages
- Conduct multi-source research and save findings
- Scrape structured data from websites

**Documents**
- Import PDF, Word, Excel, and text files
- Create PDF, Word, and PowerPoint documents
- Ask questions about imported documents

**Math and Calculations**
- Real computation using Python - no AI guessing
- Financial formulas (mortgage, compound interest, ROI, tips)
- Unit conversions (temperature, length, weight, volume, speed, data)

**Image Generation**
- Create images from text descriptions via ALICE server
- Automatic model discovery and selection
- No local GPU required

**Memory**
- Search conversation history semantically
- Store and recall important information
- Track tasks across multi-step work

### How Tools Work

When you ask SAM to do something that requires a tool, the AI decides which tool to use and calls it with the appropriate parameters. You see a real-time status card showing what SAM is doing - which file it's reading, what search it's running, what calculation it's performing.

For multi-step tasks, SAM creates a todo list, works through each step, and reports results as it goes. If something goes wrong, it adjusts its approach and tries again.

### Tool Authorization

SAM uses a path-based authorization system:
- **Inside your working directory** (`~/SAM/...`): Operations are auto-approved
- **Outside your working directory**: SAM asks for your permission first
- This prevents the AI from accidentally modifying files outside your SAM workspace

---

## Memory and Search

### Conversation Memory

SAM automatically indexes your conversations for semantic search. This means you can find past discussions by meaning, not just exact words.

**Example:** If you discussed vacation planning in an earlier conversation, searching for "travel itinerary" or "trip schedule" will find it - even if you never used those exact words.

### Searching Across Conversations

Use the search feature (F) to search across all your conversations. SAM uses vector embeddings powered by Apple's Natural Language framework to find semantically relevant results.

### Document Memory

When you import documents into a conversation, SAM chunks them into searchable segments and indexes them with vector embeddings. You can then ask questions about the content naturally:

- "What does section 3 of the report say about revenue?"
- "Summarize the key findings from the PDF I uploaded"
- "Find all mentions of the budget in my documents"

### Long-Term Memory (LTM)

SAM includes a persistent long-term memory system that survives across conversations and sessions:

- **Discoveries** - Key insights and facts learned during conversations
- **Solutions** - Problem-solving approaches that worked
- **Patterns** - Recurring patterns and best practices identified
- **Key-Value Store** - Persistent session storage for arbitrary data

The AI can access LTM through the `memory_operations` tool, and you can view LTM stats in the Performance panel.

### How Memory Works

SAM uses a Vector RAG (Retrieval-Augmented Generation) system:

1. **Chunking** - Documents and conversations are split into meaningful segments
2. **Embedding** - Each segment gets a vector embedding using Apple's NaturalLanguage framework
3. **Storage** - Embeddings are stored in a per-conversation vector database
4. **Retrieval** - When you ask a question, SAM finds the most relevant segments
5. **Augmentation** - Relevant context is included with your question to the AI

All of this happens locally on your Mac. No data leaves your machine for memory operations.

For technical details, see [docs/MEMORY.md](MEMORY.md).

---

## Documents

### Importing Documents

SAM can import and analyze several document types:

| Format | Extension | What SAM Can Do |
|--------|-----------|----------------|
| **PDF** | .pdf | Extract text, answer questions about content |
| **Word** | .docx | Extract text, analyze structure |
| **Excel** | .xlsx | Read data, analyze spreadsheets |
| **Text** | .txt, .md, .csv | Full text analysis |

To import a document:
1. Drag and drop the file into the chat window, or
2. Use the attachment button in the message input area
3. SAM processes the document and makes it available for questions

### Asking Questions About Documents

Once imported, just ask naturally:
- "What are the main points of this document?"
- "Find the section about project timelines"
- "Compare the figures in table 2 and table 5"

SAM searches through the document using semantic matching and provides answers with references to the relevant sections.

### Creating Documents

SAM can also create documents for you:

- **PDF** - Generate formatted PDF reports
- **Word** - Create .docx documents
- **PowerPoint** - Build presentations with slides
- **Excel** - Create spreadsheets
- **Markdown** - Generate .md files
- **RTF** - Rich text format

Just describe what you want: "Create a Word document summarizing our discussion about the marketing plan" and SAM generates it in your working directory.

---

## Image Generation (ALICE)

### What is ALICE?

[ALICE](https://github.com/SyntheticAutonomicMind/ALICE) (Artificial Language and Image Computing Engine) is a separate GPU-accelerated image generation server. SAM connects to an ALICE server on your network to generate images using Stable Diffusion models.

### Setting Up ALICE

1. Set up an ALICE server on a machine with a GPU (see [ALICE documentation](https://github.com/SyntheticAutonomicMind/ALICE))
2. In SAM Settings, go to the ALICE configuration section
3. Enter the ALICE server address (e.g., `http://192.168.1.100:7860`)
4. SAM automatically discovers available models on your server

### Generating Images

Just describe what you want:
- "Create an image of a sunset over mountains"
- "Generate a watercolor painting of a cat sleeping on a windowsill"
- "Make a logo for a coffee shop called Bean There"

SAM sends the request to your ALICE server, which generates the image and returns it to SAM for display.

### Features

- **Automatic model discovery** - SAM detects all models loaded on your ALICE server
- **Multiple model support** - SD 1.5, SDXL, and any other Stable Diffusion model
- **Health monitoring** - Connection status displayed in Settings
- **No local GPU required** - All generation happens on the ALICE server

---

## Math and Calculations

### Real Computation

SAM uses Python for all mathematical operations. This means you get exact, computed answers - not AI approximations. Every calculation is run through a real Python interpreter.

### What You Can Calculate

**Financial Formulas**
- Mortgage payments and amortization
- Compound interest
- ROI (Return on Investment)
- Budget planning
- Debt payoff strategies
- Retirement projections
- Loan comparisons
- Savings goals
- Net worth calculations
- Paycheck breakdowns

**Unit Conversions**
- Temperature (Fahrenheit, Celsius, Kelvin)
- Length (miles, kilometers, feet, meters, inches, centimeters)
- Weight (pounds, kilograms, ounces, grams)
- Volume (gallons, liters, cups, milliliters)
- Speed (mph, km/h, knots)
- Data (bytes, KB, MB, GB, TB)
- Time (seconds, minutes, hours, days)

**General Math**
- Arithmetic and algebra
- Percentages and tips
- BMI calculations
- Any expression Python can evaluate

### How to Use It

Just ask naturally:
- "What's the monthly payment on a $350,000 mortgage at 6.5% for 30 years?"
- "Convert 72 degrees Fahrenheit to Celsius"
- "Calculate 18% tip on $47.50"
- "What's the compound interest on $10,000 at 5% for 10 years?"

SAM automatically recognizes math requests and routes them through the computation engine instead of relying on AI reasoning.

---

## SAM-Web: Remote Access

### What is SAM-Web?

[SAM-Web](https://github.com/SyntheticAutonomicMind/SAM-web) is a web interface that lets you chat with SAM from any device on your network - iPad, iPhone, another computer, or any device with a browser.

### Requirements

1. SAM running on your Mac with the API server enabled
2. SAM-Web deployed (see [SAM-Web repository](https://github.com/SyntheticAutonomicMind/SAM-web))
3. Both devices on the same network

### Setup

1. In SAM, open Settings > API Server
2. Enable the API server
3. Note your API token
4. Deploy SAM-Web and configure it to connect to your Mac's IP
5. Open your browser and navigate to `http://your-mac-ip:8080`

### What You Can Do Remotely

- Full chat interface with all features
- Model selection
- Conversation management
- File operations (within working directory)
- Web research
- Document import/creation

---

## Shared Topics

### What Are Shared Topics?

Shared Topics are named workspaces that connect multiple conversations around a common project or subject. All conversations assigned to a Shared Topic can access the same data.

### What Gets Shared

- **Working directory** - `~/SAM/{topic-name}/` instead of per-conversation directories
- **Topic entries** - Structured data that any conversation can read/write
- **File access** - All conversations see the same files

### What Stays Separate

- **Conversation history** - Each conversation keeps its own messages
- **Document imports** - Documents imported in one conversation stay in that conversation's Vector RAG

### Creating and Using Shared Topics

1. Start a new conversation
2. Assign it to a Shared Topic (create one if needed)
3. Work normally - SAM uses the shared workspace
4. Start another conversation and assign it to the same topic
5. Both conversations can access the shared files and entries

### Use Cases

- **Project management** - Keep all project discussions connected
- **Research** - Multiple research angles sharing a common knowledge base
- **Writing** - Draft, review, and revise documents across conversations
- **Team collaboration** - Multiple conversations contributing to the same output

---

## Personality System

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

### Mini-Prompts (Custom Instructions)

Quick-action templates for common tasks. Mini-prompts provide pre-configured instructions that you can invoke with a click instead of typing out full instructions each time. In the UI, these are now called "Custom Instructions."

### System Prompt Components (SAM Default v25+)

SAM's default system prompt is built from modular components:
- **Core Identity** - WHO SAM is (helpful, accurate, approachable agent)
- **User Autonomy** - You control session boundaries, time, attention, response length
- **Scope Honesty** - All items in your scope get equal rigor; no unilateral scope-shrinking
- **Tool-Backed Claims** - Every specific claim must be verified by a tool call
- **Agent Identity & Completion Criteria** - "YOU ARE AN AGENT" framing with completion standards
- **Response Guidelines** - Quality standards, formatting, communication style
- **Tool Usage** - Principles for tool execution, math verification
- **Operational Modes** - Conversational vs Task Execution modes
- **Execution Standards** - Error recovery, completion criteria
- **Communication Protocol** - Style guide
- **Context & Memory** - Memory operations, document import
- **Data Visualization** - Mermaid diagram rendering rules
- **Workflow Mode** - Mode-specific guidance (when enabled)
- **Dynamic Iterations** - Iteration monitoring (when enabled)

---

## Preferences and Settings

### General

- **Update channel** - Stable or Development
- **Startup behavior** - New conversation or last used
- **Language** - Interface language

### AI Providers

- Add, remove, and configure providers
- Set default model per provider
- Manage API keys (stored in Keychain)

### Voice

- Wake word toggle and customization
- Text-to-speech voice, speed, devices
- Relay/conversation mode timeout

### API Server

- Enable/disable local HTTP server
- Port configuration
- API token display and regeneration
- CORS settings

### Appearance

- Theme (system, light, dark)
- Font size
- Tool card visibility

### Advanced

- Context window settings
- Memory retention policies
- Logging level

---

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| N | New conversation |
| K | Clear current conversation |
| ⇧R | Rename conversation |
| ⇧D | Duplicate conversation |
| ⇧E | Export conversation |
|  | Delete conversation |
| F | Search conversations |
| ⇧/ | Show help |
| , | Open Settings |
| W | Close window |
| Enter | Send message |
| Shift+Enter | New line in message |

---

## Tips and Best Practices

### Getting Better Results

1. **Be specific** - "Research iPhone 16 Pro reviews" works better than "Tell me about phones"
2. **Use tools explicitly** - "Search the web for..." triggers web research
3. **Import documents** - For Q&A on PDFs, import them first
4. **Use Shared Topics** - For multi-conversation projects
5. **Switch models** - Start fast, switch to capable for complex tasks

### For Local Models

1. **Close other apps** - Free up RAM for model inference
2. **Use quantized models** - Q4_K_M balances speed and quality
3. **Try CachyLLama** - Best speed on Apple Silicon
4. **Monitor memory** - Watch the Performance panel

### For Cloud Providers

1. **Start new conversations** for new topics - avoids context pollution
2. **Use OpenRouter** - Try many models with one API key
3. **Monitor costs** - Check the Performance panel for per-conversation costs

### For Voice

1. **Quiet environment** - Improves speech recognition accuracy
2. **Good microphone** - External mic works better than built-in
3. **Relay mode** - For extended hands-free sessions

---

## Troubleshooting

### "Authentication failed"
- Verify your API key is correct
- For GitHub Copilot: try signing out and back in
- Check that your account has billing configured (cloud providers)

### "Model not found"
- The model may have been renamed or deprecated
- Refresh the model list in Settings
- Check the provider's documentation for current model names

### "Rate limited"
- You've exceeded the provider's rate limits
- Wait a moment and try again
- Consider upgrading your plan or using a different provider

### "Request too large"
- Your conversation has exceeded the model's context window
- Start a new conversation
- Use a model with a larger context window
- SAM's context management should handle this automatically, but very long conversations with many tool calls can hit limits

### Local model loading fails
- Ensure you have enough free RAM
- Try a smaller model
- Check that the model file isn't corrupted (re-download if needed)
- For MLX/CachyLLama: verify you're on Apple Silicon
- For llama.cpp: verify the file is in GGUF format

### Blank window on launch
- Confirm you are on macOS 14.0 or newer
- Try resetting preferences under `~/Library/Application Support/SAM/`
- Relaunch the app

### Voice not working
- Check microphone permissions in System Settings > Privacy & Security > Microphone
- Verify wake word is enabled in SAM Settings > Voice
- Try a different audio input device

---

## FAQ

**Q: Does SAM work offline?**
A: Yes, with local models (MLX, CachyLLama, llama.cpp) and no cloud providers configured.

**Q: Can I use SAM on iPhone/iPad?**
A: Not directly, but [SAM-Web](https://github.com/SyntheticAutonomicMind/SAM-web) provides browser access from any device on your network.

**Q: How much does SAM cost?**
A: SAM itself is free (GPL-3.0). Cloud providers charge per-token. Local models are free after download.

**Q: Is my data private?**
A: Yes. All data stays on your Mac. Cloud providers only receive the messages you send them.

**Q: Can I train my own models?**
A: Yes, SAM includes LoRA training for MLX and GGUF models. See the LoRA Training section in Settings.

**Q: What's the difference between MLX and CachyLLama?**
A: MLX uses Apple's MLX framework (best quality). CachyLLama is an optimized llama.cpp fork (best speed on Apple Silicon).

**Q: How do I update SAM?**
A: Homebrew: `brew upgrade --cask sam`. Manual: Download new DMG from GitHub Releases.

**Q: Can I contribute to SAM?**
A: Yes! See [CONTRIBUTING.md](../CONTRIBUTING.md) for guidelines.