# SAM - Synthetic Autonomic Mind

**The AI assistant that actually remembers, actually works, and actually stays private.**

SAM is a native macOS AI assistant built with Swift and SwiftUI. Unlike cloud-only alternatives, SAM keeps your data on your Mac, supports multiple AI providers (including fully local models), and provides powerful tools for autonomous task execution.

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Platform](https://img.shields.io/badge/platform-macOS%2014.0%2B-lightgrey.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/swift-6.2.1%2B-orange.svg)](https://swift.org/)
[![Xcode](https://img.shields.io/badge/xcode-26.1%2B-blue.svg)](https://developer.apple.com/xcode/)

[Website](https://www.syntheticautonomicmind.org) | [Download](https://github.com/SyntheticAutonomicMind/SAM/releases)

---

## What Makes SAM Different

🔐 **Privacy First**
- All data stays on your Mac - nothing sent to the cloud unless you choose
- Run completely offline with local AI models (MLX/GGUF)
- API keys stored securely in macOS Keychain
- Zero telemetry, zero tracking

🧠 **Intelligent Memory System**
- Vector RAG for semantic search across conversations
- Import documents (PDF, DOCX, XLSX, TXT) and search them
- Shared Topics for multi-conversation collaboration
- Conversation-scoped memory prevents data leakage

🤖 **Autonomous Workflows**
- Multi-step task execution with tool orchestration
- Spawn subagents for parallel work
- Up to 300 iterations per task
- Dynamic iteration requests for complex projects

🛠️ **Comprehensive MCP Tools**
- File operations, terminal access, web research
- Git integration, build automation
- Document import and creation
- Image generation with Stable Diffusion

🎨 **Stable Diffusion Image Generation**
- SD 1.5, SDXL, Z-Image, Flux model support
- Browse and download from HuggingFace and CivitAI
- LoRA support for style customization
- CoreML optimization for Apple Silicon

🌐 **Multi-Provider AI Support**
- **Cloud**: OpenAI, Anthropic, GitHub Copilot, Google Gemini, xAI Grok
- **Local**: MLX (Apple Silicon optimized), GGUF (llama.cpp)
- Switch models mid-conversation
- Custom OpenAI-compatible endpoints

---

## Quick Start

### Download & Install

1. **Download** the latest release from [GitHub Releases](https://github.com/SyntheticAutonomicMind/SAM/releases)
2. **Extract** `SAM.app.zip`
3. **Move** `SAM.app` to your Applications folder
4. **First Launch**: Right-click SAM.app → Open (macOS Gatekeeper requirement, only needed once)

### Configure AI Provider

1. Launch SAM
2. Open Preferences (`⌘,`)
3. Go to **AI Providers** tab
4. Click **Add Provider**
5. Choose your provider (OpenAI, Claude, GitHub Copilot, or Local Model)
6. Enter API key (or select local model)
7. Save and start chatting!

### Your First Conversation

```
Press ⌘N to create a new conversation
Type: "Hello! What can you help me with?"
Press Enter and SAM will introduce itself
```

---

## Key Features Overview

### 🎯 Core Capabilities

**Conversations**
- Unlimited conversations with auto-save
- Export to JSON or Markdown
- Rename, duplicate, and organize
- Switch models mid-conversation

**Streaming Responses**
- Real-time token-by-token streaming
- Watch SAM think and work
- Cancel generation anytime
- Progress indicators for tools

**Memory System**
- Vector RAG for semantic search
- Import documents (PDF, DOCX, XLSX, TXT)
- Per-conversation memory isolation
- Shared Topics for cross-conversation collaboration

**Autonomous Execution**
- Multi-step task handling
- Tool orchestration
- Subagent spawning
- Up to 300 iterations per task

### 🤖 AI Provider Support

| Provider | Models | Context | Notes |
|----------|--------|---------|-------|
| **OpenAI** | GPT-4, GPT-4o, GPT-3.5, o1/o3 | 8k-128k | General purpose |
| **Anthropic** | Claude 3.5 Sonnet, Claude 4 | 90k-200k | Long context |
| **GitHub Copilot** | GPT-4o, Claude 3.5, o1 | Varies | Requires subscription |
| **Google Gemini** | Gemini 2.0 Flash, 1.5 Pro | 1M-2M | Massive context |
| **xAI Grok** | Grok-2, Grok Vision | 128k | Multimodal |
| **Local MLX** | Qwen, Llama, Phi, Mistral | Varies | Apple Silicon only |
| **Local GGUF** | Any GGUF model | Varies | Works on any Mac |

### 🛠️ MCP Tools

**File & Terminal**
- Read, write, search, edit files
- Execute terminal commands
- PTY sessions for persistent terminals
- Working directory management

**Memory & Planning**
- Store and retrieve memories
- Agent todo list management (for AI task tracking)
- Workflow tracking
- Context persistence

**Web & Research**
- Web search (Google, Bing, Scholar)
- Web scraping
- Content extraction
- Research synthesis

**Build & VCS**
- Git operations (commit, diff, status)
- Build automation
- Error checking
- Code search

**Documents & Images**
- Import PDF, DOCX, XLSX, TXT
- Create formatted documents
- Generate images with Stable Diffusion
- LoRA management

See [project-docs/MCP_TOOLS_SPECIFICATION.md](project-docs/MCP_TOOLS_SPECIFICATION.md) for complete tool documentation.

### 🎨 Image Generation

**Supported Models**
- Stable Diffusion 1.5 (512×512)
- Stable Diffusion XL (1024×1024)
- Z-Image (bfloat16 optimized)
- Flux models

**Features**
- Browse HuggingFace and CivitAI
- LoRA support for style customization
- CoreML optimization (fast inference)
- Python fallback (full features)
- Real-ESRGAN upscaling
- img2img generation

See [project-docs/STABLE_DIFFUSION.md](project-docs/STABLE_DIFFUSION.md) for image generation documentation.

### 🎭 Personalities

Choose from multiple built-in personalities to customize SAM's communication style:

- **General**: SAM (default), Generic, Concise
- **Tech**: Developer, Architect, Code Reviewer, Tinkerer, Crusty Coder, BOFH, Tech Buddy
- **Experts**: Doctor, Counsel, Finance Coach, Trader, Scientist, Philosopher
- **Creative**: Creative Catalyst, DocuGenie, Prose Pal, Prompt Pal
- **Productivity**: Fitness Fanatic, Motivator
- **Fun**: Comedian, Pirate, Time Traveler, Jester

---

## System Requirements

**Minimum:**
- macOS 14.0 (Sonoma) or later
- 4GB RAM
- 3GB free disk space (for SAM application)

**Recommended:**
- macOS 14.0+ (Sonoma or Sequoia)
- 8GB+ RAM (16GB for local models)
- 20GB+ free space (includes models and generated content)
- Apple Silicon (M1/M2/M3/M4) for best performance

**For Local Models:**
- MLX models require Apple Silicon
- GGUF models work on any Mac (Intel or Apple Silicon)

---

## Building from Source

### Prerequisites
- macOS 14.0+
- Xcode 26.1+ with Swift 6.2.1+
- cmake (for llama.cpp): `brew install cmake`

### Build Steps

1. **Clone the repository:**
   ```bash
   git clone https://github.com/SyntheticAutonomicMind/SAM.git
   cd SAM
   ```

2. **Initialize submodules:**
   ```bash
   git submodule update --init --recursive
   ```

3. **Build:**
   ```bash
   # Debug build
   make build-debug
   
   # Release build
   make build-release
   ```

4. **Run:**
   ```bash
   # Run from build directory
   .build/Build/Products/Debug/SAM.app/Contents/MacOS/SAM
   
   # Or use make
   make run
   ```

**For complete build instructions**, see [BUILDING.md](BUILDING.md).

---

## Documentation

Complete technical documentation is available in the [`project-docs/`](project-docs/) directory.

**Methodology:**
- **[The Unbroken Method](project-docs/THE_UNBROKEN_METHOD.md)** - Complete AI collaboration framework

**Core Architecture:**
- **[API Framework](project-docs/API_FRAMEWORK.md)** - Provider system, endpoints, authentication
- **[MCP Framework](project-docs/MCP_FRAMEWORK.md)** - Model Context Protocol implementation
- **[Conversation Engine](project-docs/CONVERSATION_ENGINE.md)** - Chat processing and state management
- **[Messaging Architecture](project-docs/MESSAGING_ARCHITECTURE.md)** - Message flow and transformations

**Subsystems:**
- **[Stable Diffusion](project-docs/STABLE_DIFFUSION.md)** - Image generation, models, schedulers
- **[MLX Integration](project-docs/MLX_INTEGRATION.md)** - Local model support (Apple Silicon)
- **[Sound System](project-docs/SOUND.md)** - Voice input/output, wake word detection
- **[Mermaid Architecture](project-docs/MERMAID_ARCHITECTURE.md)** - Diagram rendering

**Specifications:**
- **[MCP Tools](project-docs/MCP_TOOLS_SPECIFICATION.md)** - Complete tool API reference
- **[API Integration](project-docs/API_INTEGRATION_SPECIFICATION.md)** - Provider integration guide
- **[Security](project-docs/SECURITY_SPECIFICATION.md)** - Security model and sandboxing
- **[Memory & Intelligence](project-docs/MEMORY_AND_INTELLIGENCE_SPECIFICATION.md)** - RAG and memory system

**Flow Documentation:**
- **[Message Flow](project-docs/flows/message_flow.md)** - End-to-end message processing
- **[Tool Execution](project-docs/flows/tool_execution_flow.md)** - Tool invocation and results
- **[SD Generation](project-docs/flows/sd_generation_flow.md)** - Image generation pipeline
- **[Model Loading](project-docs/flows/model_loading_flow.md)** - Local model initialization

---

## Privacy & Security

### Your Data Stays Local
- **Conversations**: `~/Library/Application Support/SAM/conversations/`
- **Memories**: Per-conversation SQLite databases
- **API Keys**: Encrypted in macOS Keychain
- **No Telemetry**: Zero usage tracking, zero data collection

### Security Features
- Authorization system for file/terminal operations
- Working directory sandboxing
- Per-conversation memory isolation
- Optional auto-approve for trusted operations
- Full audit trail of all tool executions

---

## Use Cases

**For Everyone:**
- Answer questions and provide information
- Help write and edit documents
- Research topics and summarize findings
- Organize and manage files
- Generate images from descriptions

**For Developers:**
- Code review and debugging
- Documentation generation
- Build automation and testing
- Git operations and version control
- Codebase search and refactoring

**For Researchers:**
- Document analysis and summarization
- Web research and fact-checking
- Data visualization
- Cross-reference multiple sources
- Literature review automation

**For Content Creators:**
- Writing assistance and editing
- Image generation for blogs/social media
- Content organization
- Research and fact-checking
- SEO optimization

---

## File Locations

### Application Data
```
~/Library/Application Support/SAM/
├── conversations/              # Conversation files (JSON)
├── config.json                 # Global configuration
└── conversations/{id}/
    └── memory.db              # Per-conversation memory
```

### Models
```
~/Library/Caches/sam/models/
├── mlx/                       # MLX models (Apple Silicon)
├── gguf/                      # GGUF models (llama.cpp)
└── stable-diffusion/          # SD models and LoRAs
```

### Working Directories
```
~/SAM/
├── conversation-{number}/     # Per-conversation workspace
└── {topic-name}/              # Shared Topic workspace
```

### Generated Content
```
~/Library/Caches/sam/
├── images/                    # Generated images
└── staging/                   # Temporary files
```

---

## Contributing

We welcome contributions! Here's how you can help:

### Getting Started
1. Fork the repository
2. Create a feature branch: `git checkout -b feature/your-feature`
3. Make your changes following our code style
4. Run tests and linting
5. Commit with clear messages: `git commit -m "feat(scope): description"`
6. Push and create a pull request

### Commit Message Format
Follow Conventional Commits:
- `feat(scope): Add new feature`
- `fix(scope): Fix bug`
- `refactor(scope): Refactor code`
- `docs(scope): Update documentation`
- `test(scope): Add or update tests`

### Areas for Contribution
- New MCP tools
- Additional AI provider support
- UI/UX improvements
- Documentation
- Bug fixes
- Performance optimization

**For contribution guidelines**, see [CONTRIBUTING.md](CONTRIBUTING.md).

---

## Support

### Getting Help
- **Documentation**: [`project-docs/`](project-docs/) directory
- **Issues**: [GitHub Issues](https://github.com/SyntheticAutonomicMind/SAM/issues)
- **Discussions**: [GitHub Discussions](https://github.com/SyntheticAutonomicMind/SAM/discussions)

### Troubleshooting

**SAM won't open?**
```bash
# Remove macOS quarantine attribute
xattr -d com.apple.quarantine /Applications/SAM.app
```

**Model not showing up?**
```bash
# Check model directory
ls ~/Library/Caches/sam/models/mlx/
ls ~/Library/Caches/sam/models/gguf/
# Restart SAM
```

**API key issues?**
- Verify key in Preferences → AI Providers
- Check provider website for key status
- Review error messages in conversation

---

## Technology Stack

- **Language**: Swift 6.2.1+
- **Build Requirements**: Xcode 26.1+, Swift 6.2.1+
- **UI Framework**: SwiftUI (native macOS)
- **Server**: Vapor 4 (embedded HTTP/SSE)
- **Persistence**: SQLite (conversations, memory)
- **AI Integration**: OpenAI-compatible APIs
- **Local Models**: MLX (Apple Silicon), llama.cpp
- **Image Generation**: Stable Diffusion (CoreML + Python)
- **Concurrency**: Swift 6 strict concurrency enabled

### System Requirements

**For Users:**
- macOS 14.0 (Sonoma) or later
- Apple Silicon (M1/M2/M3) recommended for local models
- 8GB RAM minimum, 16GB+ recommended
- 10GB free disk space (more for local models)

**For Developers:**
- macOS 14.0+ (Sonoma or later)
- Xcode 26.1 or later
- Swift 6.2.1 or later
- Command Line Tools installed
- Homebrew (for dependencies like cmake)

---

## License & Credits

**License**: GPLv3 - See [LICENSE](LICENSE) for details

**Created by**: Andrew Wyatt (Fewtarius)  
**Website**: https://syntheticautonomicmind.org  
**Repository**: https://github.com/SyntheticAutonomicMind/SAM

**Built with:**
- Vapor (Web framework)
- MLX (Apple machine learning)
- llama.cpp (LLM inference)
- Stable Diffusion (Image generation)
- Sparkle (App updates)

Special thanks to all contributors and the Swift/AI communities.

---

**Ready to get started?** [Download SAM](https://github.com/SyntheticAutonomicMind/SAM/releases) or explore our [documentation](project-docs/) to learn more!
