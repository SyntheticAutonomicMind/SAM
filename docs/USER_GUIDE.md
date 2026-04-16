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

1. **Set up an AI provider** - Open Settings (⌘,) and go to the AI Providers tab
2. **Choose your provider:**
   - **Cloud AI** - OpenAI, GitHub Copilot, DeepSeek, Google Gemini, MiniMax, or OpenRouter (Claude models available via OpenRouter)
   - **Local AI** - Download and run a model directly on your Mac (Apple Silicon recommended)
3. **Enter your API key** (for cloud providers)
4. **Start chatting** - Press ⌘N for a new conversation, type your message, and press Enter

### System Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon (M1/M2/M3/M4) recommended for local models
- Intel Macs supported (cloud providers and llama.cpp local models)
- 8GB RAM minimum, 16GB+ recommended for local models

---

## Conversations

### Creating and Managing Conversations

- **New conversation** - Press ⌘N or click the + button in the sidebar
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
| **MiniMax** | MiniMax-M2.7, M2.5 | 128K context, competitive pricing |
| **OpenRouter** | 100+ models | Access many providers through one API |

### Local Models

Run AI completely on your Mac with no internet connection required:

| Engine | Best For | Requirements |
|--------|----------|-------------|
| **MLX** | Apple Silicon Macs | M1+ chip, 8GB+ RAM |
| **llama.cpp** | Any Mac (Intel or Apple Silicon) | 8GB+ RAM |

Local models are downloaded once and run entirely offline. SAM includes a model browser in Settings where you can discover, download, and manage local models.

### Setting Up a Provider

1. Open Settings (⌘,)
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

Use the search feature (⌘F) to search across all your conversations. SAM uses vector embeddings powered by Apple's Natural Language framework to find semantically relevant results.

### Document Memory

When you import documents into a conversation, SAM chunks them into searchable segments and indexes them with vector embeddings. You can then ask questions about the content naturally:

- "What does section 3 of the report say about revenue?"
- "Summarize the key findings from the PDF I uploaded"
- "Find all mentions of the budget in my documents"

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

- Chat with SAM
- Use mini-prompts
- Select AI models
- View conversation history
- Access core features

**Note:** Some advanced features (voice control, local model management, document import) require the native macOS app.

---

## Shared Topics

### What Are Shared Topics?

Shared Topics let multiple conversations share the same context and workspace. Think of them as project folders - everything related to a project lives in one place, and any conversation can access it.

### Creating a Shared Topic

1. Start a new conversation
2. Assign it to a Shared Topic (or create a new one)
3. All conversations assigned to that topic share:
   - A common working directory (`~/SAM/{topic-name}/`)
   - Shared file access
   - Cross-conversation context

### Use Cases

- **Project management** - Keep all discussions about a project connected
- **Research** - Multiple research conversations that build on each other
- **Writing** - Draft, review, and revise documents across conversations
- **Learning** - Study sessions that share notes and materials

### How It Works

Shared Topics use a SQLite database to store topic metadata, entries, and file references. Each topic has:
- A name and description
- A dedicated file directory
- Entries that any conversation in the topic can access
- Optimistic locking for safe concurrent access

---

## Personality System

### Built-In Personalities

SAM comes with several personality options that change how it communicates:

- **Friendly** - Warm, conversational, uses casual language
- **Professional** - Formal, precise, business-appropriate
- **Creative** - Imaginative, expressive, uses metaphors and analogies
- **Custom** - Define your own personality

### Customizing SAM's Personality

In Settings, you can adjust personality traits to fine-tune how SAM communicates. This affects the tone, vocabulary, and style of SAM's responses without changing what it can do.

### System Prompts

Advanced users can customize SAM's system prompt - the instructions that define SAM's behavior. SAM includes a system prompt editor in Settings where you can:
- View and edit the active system prompt
- Save custom system prompts
- Switch between prompt configurations

---

## Preferences and Settings

Open Settings with ⌘, (Command + Comma).

### General

- **Appearance** - Light mode, dark mode, or follow system
- **Development updates** - Opt in to receive pre-release builds
- **Auto-updates** - SAM checks for updates automatically via Sparkle

### AI Providers

- Add, configure, and remove AI providers
- Set default model
- Manage API keys
- Configure custom endpoints

### Voice

- **Wake word** - Enable/disable "Hey SAM" activation
- **Text-to-speech** - Enable/disable SAM speaking responses
- **Voice selection** - Choose from macOS system voices
- **Speech rate** - Adjust speaking speed
- **Audio devices** - Select input and output devices

### ALICE

- Configure ALICE server connection
- View server health and available models
- Set generation defaults

### API Server

- Enable/disable the local API server (for SAM-Web)
- View and copy API authentication token
- Configure server port

### Working Directory

- View and change the base working directory for conversations
- Default: `~/SAM/`

---

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘N | New conversation |
| ⌘K | Clear current conversation |
| ⌘⇧R | Rename conversation |
| ⌘⇧D | Duplicate conversation |
| ⌘⇧E | Export conversation |
| ⌘⌫ | Delete conversation |
| ⌘F | Search conversations |
| ⌘⇧/ | Show help |
| ⌘, | Open Settings |
| ⌘W | Close window |
| Enter | Send message |
| Shift+Enter | New line in message |

---

## Tips and Best Practices

### Getting Better Results

1. **Be specific** - "Write a professional email declining a meeting" works better than "write an email"
2. **Provide context** - "I'm planning a trip to Japan in April" gives SAM more to work with than "tell me about Japan"
3. **Use follow-ups** - Build on the conversation. SAM remembers everything in the current chat.
4. **Import documents** - Instead of pasting text, import the full document so SAM can search it properly
5. **Use Shared Topics** - For ongoing projects, keep everything connected in a Shared Topic

### Saving Money on Cloud Providers

1. **Start with smaller models** - Use GPT-3.5 or DeepSeek for simple tasks, upgrade to GPT-4o or Claude for complex ones
2. **Use local models** - For private or simple tasks, local models are free after download
3. **Keep conversations focused** - Long conversations with lots of context cost more tokens

### Privacy Tips

1. **Use local models** for sensitive content - nothing leaves your Mac
2. **Each conversation is isolated** - the AI in one conversation doesn't see another
3. **Shared Topics share context** - be intentional about what you put in shared topics
4. **API keys are stored locally** in your Mac's Keychain
5. **SAM has zero telemetry** - no usage data is collected or sent anywhere

---

## Troubleshooting

### SAM Won't Launch

- Ensure you're running macOS 14.0 or later
- Try right-clicking SAM.app and selecting Open (bypasses Gatekeeper)
- Check Console.app for crash logs

### AI Provider Not Responding

- Verify your API key is correct in Settings
- Check your internet connection (cloud providers)
- Try a different model or provider
- Check the provider's status page for outages

### Local Models Are Slow

- Apple Silicon Macs perform significantly better with MLX models
- Close other memory-intensive applications
- Try a smaller model (7B parameters instead of 13B+)
- Ensure you have enough free RAM (model size + 4GB overhead)

### Voice Control Not Working

- Check microphone permissions in System Settings > Privacy & Security > Microphone
- Ensure the wake word is enabled in SAM Settings > Voice
- Verify your microphone is selected as the input device
- Try a quiet environment - background noise can interfere with wake word detection

### Documents Not Importing

- Check that the file format is supported (PDF, DOCX, XLSX, TXT)
- Ensure the file isn't corrupted or password-protected
- Try a smaller file - very large documents may take time to process
- Check available disk space

### SAM-Web Can't Connect

- Verify SAM is running on your Mac with the API server enabled
- Check that both devices are on the same network
- Confirm the correct IP address and port
- Verify the API token matches

---

## FAQ

### Is SAM free?

Yes. SAM is free and open source under the GPL-3.0 license. You'll need your own API keys for cloud AI providers, or you can run local models at no cost.

### Does SAM send my data to the cloud?

Only when you use a cloud AI provider, and only the minimum context needed for the AI to respond. All conversation history, documents, and memory stay on your Mac. SAM has zero telemetry.

### Can I use SAM offline?

Yes, with local models (MLX or llama.cpp). Download a model once, then use SAM with no internet connection.

### What's the difference between MLX and llama.cpp?

MLX is optimized for Apple Silicon Macs and offers the best performance on M1+ chips. llama.cpp works on both Intel and Apple Silicon Macs but may be slower. If you have an Apple Silicon Mac, use MLX.

### Can I use SAM with my own OpenAI-compatible server?

Yes. SAM supports any OpenAI-compatible API endpoint. Configure it as a custom provider in Settings.

### How much RAM do I need for local models?

It depends on the model size. Rough guidelines:
- 7B parameter models: 8GB+ RAM
- 13B parameter models: 16GB+ RAM
- 70B parameter models: 64GB+ RAM (Apple Silicon unified memory)

The model needs to fit in memory along with macOS and SAM itself.

### Does SAM work on Intel Macs?

Yes, but with limitations. Cloud AI providers work on any Mac. For local models, Intel Macs can use llama.cpp but not MLX (which requires Apple Silicon). Performance will be slower than Apple Silicon.

### How do I update SAM?

If installed via Homebrew: `brew upgrade --cask sam`

Otherwise, SAM checks for updates automatically using Sparkle. You'll see a notification when a new version is available. You can also check manually in the app.

### Can I contribute to SAM?

Absolutely. SAM is open source and welcomes contributions. See [CONTRIBUTING.md](../CONTRIBUTING.md) for guidelines, or visit the [GitHub repository](https://github.com/SyntheticAutonomicMind/SAM).

---

## See Also

- [Features Guide](FEATURES.md) - Complete feature reference
- [Architecture](ARCHITECTURE.md) - How SAM is built
- [Providers Guide](PROVIDERS.md) - Detailed AI provider setup
- [Memory System](MEMORY.md) - How memory and search work
- [Tools Reference](TOOLS.md) - What SAM's tools can do
- [Security](SECURITY.md) - Privacy and security model
- [Installation](INSTALLATION.md) - Detailed installation guide
- [Building from Source](../BUILDING.md) - For developers
- [Contributing](../CONTRIBUTING.md) - How to contribute
