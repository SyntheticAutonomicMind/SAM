# SAM - Synthetic Autonomic Mind

**The AI assistant that actually remembers, actually works, and actually stays private.**

SAM is a native macOS AI assistant built with Swift and SwiftUI. Unlike cloud-only alternatives, SAM keeps your data on your Mac, supports multiple AI providers (including fully local models), and provides powerful tools for autonomous task execution.

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Platform](https://img.shields.io/badge/platform-macOS%2014.0%2B-lightgrey.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/swift-6.0%2B-orange.svg)](https://swift.org/)

[Website](https://www.syntheticautonomicmind.org) | [Download](https://github.com/SyntheticAutonomicMind/SAM/releases)

---

## What Makes SAM Different

🔐 **Privacy First**
- All data stays on your Mac - nothing sent to the cloud unless you choose
- Run completely offline with local AI models
- API credentials stored locally in UserDefaults
- Zero telemetry, zero tracking

🧠 **Intelligent Memory**
- Remember and search across all your conversations
- Import documents (PDF, Word, Excel, text) and ask questions about them
- Share context between conversations when you need it
- Keep conversations private from each other when you don't

🤖 **Gets Work Done**
- Multi-step task execution - describe what you want, SAM handles the details
- Work with files, run commands, research the web
- Generate documents and images
- Handle complex projects autonomously

🛠️ **Powerful Tools**
- Read, edit, and search files
- Run terminal commands
- Research and browse the web
- Work with Git repositories
- Generate images with Stable Diffusion

🎨 **Image Generation**
- Multiple Stable Diffusion models supported
- Browse and download from HuggingFace and CivitAI
- LoRA support for style customization
- Optimized for Apple Silicon

🎓 **Train Your Own Models**
- Fine-tune local AI models with LoRA (Low-Rank Adaptation)
- Train on your conversations or documents
- Custom adapters for specialized knowledge domains
- Real-time training progress with loss visualization

🌐 **Access Anywhere**
- Use SAM from your iPad, iPhone, or any device with a browser
- Web interface (SAM-Web) provides chat and basic features remotely
- Connect over your local network (requires SAM running on Mac)
- Secure API authentication

🌐 **Flexible AI Provider Support**
- **Cloud AI**: OpenAI, Anthropic (Claude), GitHub Copilot, DeepSeek
- **Local Models**: Run AI completely on your Mac with MLX or llama.cpp
- Switch models mid-conversation
- Use custom OpenAI-compatible endpoints

---

## Quick Start

### Download & Install

1. **Download** the latest release from [GitHub Releases](https://github.com/SyntheticAutonomicMind/SAM/releases)
2. **Extract** the downloaded zip file
3. **Move** `SAM.app` to your Applications folder
4. **First Launch**: Right-click SAM.app → Open (macOS Gatekeeper requirement, only needed once)

### Set Up Your AI Provider

1. Launch SAM
2. Open Settings (`⌘,`)
3. Go to **AI Providers** tab
4. Click **Add Provider**
5. Choose your provider:
   - **Cloud AI**: OpenAI, Claude, GitHub Copilot, or DeepSeek
   - **Local Model**: Choose a model to download and run on your Mac
6. For cloud providers: Enter your API key
7. Save and start chatting!

### Start Your First Conversation

Press `⌘N` to create a new conversation, type your message, and press Enter. SAM will respond and can help you with questions, writing, coding, research, file management, and much more.

### Access SAM from Other Devices

Want to use SAM from your iPad or phone? Check out **[SAM-Web](https://github.com/SyntheticAutonomicMind/SAM-web)** - a web interface that provides chat functionality and basic features when you're away from your Mac.

**What you need:**
1. SAM running on your Mac with API Server enabled (Preferences → API Server)
2. Get your API token from the same preferences pane
3. Visit the [SAM-Web repository](https://github.com/SyntheticAutonomicMind/SAM-web) for setup instructions
4. Connect from your browser at `http://your-mac-ip:8080`

**Note:** SAM-Web provides chat, mini-prompts, and conversation basics. Advanced features require the native macOS app.

---

## Development Program

SAM offers a development channel for users who want early access to new features and are willing to help test pre-release builds.

### What are Development Builds?

Development builds are released frequently (sometimes daily) and contain:
- ✨ New features before they reach stable release
- 🐛 Bug fixes and improvements being tested
- ⚠️ Potentially incomplete features or breaking changes

**Development builds are intended for testing and feedback only.** They may contain bugs or unstable behavior. Do not use development builds for critical production work.

### How to Enable Development Updates

1. Open SAM Preferences (`⌘,`)
2. Go to the **General** tab
3. Enable **"Receive development updates"**
4. Confirm the warning about potential instability
5. SAM will now check for both development and stable releases

You can disable development updates at any time to return to stable releases only.

### Development vs Stable Releases

| Feature | Stable Releases | Development Releases |
|---------|----------------|----------------------|
| **Version Format** | `YYYYMMDD.RELEASE` (e.g., `20260110.1`) | `YYYYMMDD.RELEASE-dev.BUILD` (e.g., `20260110.1-dev.1`) |
| **Release Frequency** | Weekly or bi-weekly | Daily or multiple per day |
| **Testing** | Fully tested and documented | Pre-release testing |
| **Stability** | Production-ready | May contain bugs |
| **Who Gets Them** | All users by default | Only users who opt-in |

### Providing Feedback

If you're using development builds and encounter issues:
1. Check [GitHub Issues](https://github.com/SyntheticAutonomicMind/SAM/issues) to see if it's already reported
2. Create a new issue with:
   - Your SAM version (shown in About SAM or Preferences)
   - Steps to reproduce the problem
   - Expected vs actual behavior
   - Relevant logs (Help → Show Logs)

Your feedback helps make SAM better for everyone!

---

## Key Features

### 💬 Conversations

- Unlimited conversations with automatic saving
- Export to JSON or Markdown
- Rename, duplicate, and organize conversations
- Switch AI models mid-conversation

### 🧠 Memory & Documents

- Search across all your conversations semantically
- Import documents (PDF, Word, Excel, text files) and ask questions about them
- Search by filename and content with enhanced metadata
- Share context between conversations when needed
- Keep conversations private from each other by default

### 🤖 AI Provider Support

| Provider | What You Get |
|----------|--------------|
| **OpenAI** | GPT-4, GPT-4o, GPT-3.5, o1/o3 models |
| **Anthropic** | Claude 3.5 Sonnet, Claude 4 (long context) |
| **GitHub Copilot** | GPT-4o, Claude 3.5, o1 (requires subscription) |
| **DeepSeek** | Cost-effective AI models |
| **Local MLX** | Run models on Apple Silicon Macs |
| **Local llama.cpp** | Run models on any Mac (Intel or Apple Silicon) |
| **Custom** | Use any OpenAI-compatible API |

### 🛠️ What SAM Can Do

**Work with Files**
- Read, write, search, and edit files
- Find files by name or content
- Get file information

**Execute Commands**
- Run terminal commands
- Manage persistent terminal sessions
- Execute shell scripts

**Research & Web**
- Search the web (Google, Bing, and more)
- Scrape and analyze web pages
- Gather and synthesize information from multiple sources

**Development Tools**
- Git operations (commit, diff, status)
- Build and run tasks
- Search code and check for errors

**Documents & Images**
- Import and analyze PDF, Word, Excel, and text files
- Create formatted documents (PDF, Word, PowerPoint)
- Generate images with Stable Diffusion

### 🎨 Image Generation

- Multiple Stable Diffusion models (SD 1.5, SDXL, and more)
- Browse and download models from HuggingFace and CivitAI
- LoRA support for custom styles
- Optimized for Apple Silicon Macs

### 🎓 LoRA Training

Train custom AI models on your own data:

- **Fine-Tune Local Models**: Specialize MLX models on specific knowledge domains
- **Training Data Export**: Export conversations or documents as training data
- **Flexible Configuration**: Customize rank, learning rate, epochs, and more
- **Real-Time Progress**: Watch training progress with loss visualization
- **Automatic Integration**: Trained adapters appear immediately in model picker
- **Document Chunking**: Multiple strategies for processing long documents
- **PII Protection**: Optional detection and redaction of sensitive information
### 🌐 SAM-Web: Remote Access

Access SAM chat from other devices on your network:

- **Web Interface**: Chat with SAM from your browser (requires SAM running on Mac)
- **Multi-Device Support**: Use from iPad, iPhone, tablets, or other computers
- **Core Features**: Conversations, mini-prompts, model selection, and chat
- **Responsive Design**: Optimized for desktop, tablet, and mobile screens
- **Secure Access**: Token-based authentication
- **Easy Setup**: No installation on remote device, just open browser

Visit the [SAM-Web repository](https://github.com/SyntheticAutonomicMind/SAM-web) for setup instructions.

**Note:** SAM-Web is a companion interface, not a replacement. Full SAM features require the native macOS app.
- **All Features Available**: Chat, tools, settings, prompts, and more

Visit the [SAM-Web repository](https://github.com/SyntheticAutonomicMind/SAM-web) for setup instructions.

### 🎭 Personalities

Choose from built-in personalities to customize how SAM communicates:

- **General Purpose**: SAM (default), Generic, Concise
- **Tech & Development**: Developer, Architect, Code Reviewer, Tech Buddy
- **Domain Experts**: Doctor, Counsel, Finance Coach, Scientist, Philosopher
- **Creative Writing**: Creative Catalyst, DocuGenie, Prose Pal
- **Productivity**: Fitness Fanatic, Motivator
- **Fun Characters**: Comedian, Pirate, Time Traveler, Jester

And many more! You can also create custom personalities.

---

## System Requirements

**To Use SAM:**
- macOS 14.0 (Sonoma) or later
- 4GB RAM minimum (8GB+ recommended)
- 3GB free disk space for the app

**For Local AI Models:**
- 16GB+ RAM recommended
- 20GB+ free disk space (models can be large)
- Apple Silicon (M1/M2/M3/M4) recommended for best performance with MLX
- Intel Macs can use llama.cpp models

---

## Building from Source

For developers who want to build SAM from source, see [BUILDING.md](BUILDING.md) for complete instructions.

---

## Documentation

Complete documentation is available:

- **[Website](https://www.syntheticautonomicmind.org)** - User guides and tutorials
- **[project-docs/](project-docs/)** - Technical documentation for developers
- **[BUILDING.md](BUILDING.md)** - Build instructions
- **[CONTRIBUTING.md](CONTRIBUTING.md)** - How to contribute

---

## Privacy & Security

### Your Data Stays on Your Mac

- **Conversations**: Stored locally in `~/Library/Application Support/SAM/`
- **Memory**: Per-conversation databases, never shared between conversations
- **API Keys**: Stored in UserDefaults for provider credentials
- **No Telemetry**: Zero usage tracking, zero data collection

When you use cloud AI providers (OpenAI, Claude, etc.), only the messages you send go to those providers. SAM never sends telemetry or analytics anywhere.

### Security Features

- Authorization system for file and terminal operations
- Per-conversation memory isolation prevents data leakage
- Optional auto-approve for operations you trust
- Full audit trail of all actions

---

## What Can You Do with SAM?

**For Everyone:**
- Get answers to questions with AI that can search the web and your documents
- Write and edit documents with AI assistance
- Research topics and get comprehensive summaries
- Organize and manage files on your Mac
- Generate images from text descriptions

**For Developers:**
- Review code and find bugs
- Generate documentation automatically
- Automate builds and testing
- Work with Git repositories
- Search and refactor codebases

**For Researchers:**
- Analyze and summarize documents
- Research topics across the web
- Cross-reference multiple sources
- Create visualizations and diagrams

**For Content Creators:**
- Writing assistance and editing
- Generate images for blogs and social media
- Organize research and content
- Fact-checking and research

---

## Where SAM Stores Your Data

### Your Conversations and Settings
```
~/Library/Application Support/SAM/
├── conversations/              # Your conversation files
├── config.json                 # App settings
└── conversations/{id}/
    └── memory.db              # Memories for each conversation
```

### Downloaded AI Models
```
~/Library/Caches/sam/models/
├── mlx/                       # MLX models (Apple Silicon)
├── gguf/                      # llama.cpp models
└── stable-diffusion/          # Stable Diffusion models and LoRAs
```

### Working Files
```
~/SAM/
├── conversation-{number}/     # Working files for each conversation
└── {topic-name}/              # Shared workspace for topics
```

### Generated Images
```
~/Library/Caches/sam/images/   # Images created by Stable Diffusion
```

---

## Contributing

We welcome contributions! To contribute:

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/your-feature`
3. Make your changes
4. Test your changes
5. Commit with clear messages
6. Push and create a pull request

See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines.

---

## Getting Help

### Having Trouble?

**SAM won't open after downloading?**
```bash
# Remove macOS quarantine attribute
xattr -d com.apple.quarantine /Applications/SAM.app
```

**Model not showing up in the model list?**
- Check that models are in `~/Library/Caches/sam/models/mlx/` or `~/Library/Caches/sam/models/gguf/`
- Restart SAM after adding new models

**API key issues?**
- Verify your API key in Settings → AI Providers
- Check that your API key is active on the provider's website
- Review any error messages in the conversation

### Need More Help?

- **Documentation**: [Website](https://www.syntheticautonomicmind.org) and [project-docs/](project-docs/)
- **Report Issues**: [GitHub Issues](https://github.com/SyntheticAutonomicMind/SAM/issues)
- **Discussions**: [GitHub Discussions](https://github.com/SyntheticAutonomicMind/SAM/discussions)

---

## Technical Details

SAM is built with:
- **Swift 6** with strict concurrency
- **SwiftUI** for native macOS interface
- **Vapor** for embedded HTTP/SSE server
- **SQLite** for conversation and memory storage
- **MLX** for Apple Silicon AI models
- **llama.cpp** for cross-platform AI models
- **Stable Diffusion** (CoreML + Python) for image generation

For developers interested in the technical architecture, see [project-docs/](project-docs/).

---

## License & Credits

**License**: GPLv3 - See [LICENSE](LICENSE) for details

**Created by**: Andrew Wyatt (Fewtarius)  
**Website**: https://syntheticautonomicmind.org  
**Repository**: https://github.com/SyntheticAutonomicMind/SAM

**Built with open source:**
- [Vapor](https://vapor.codes) - Web framework
- [MLX](https://github.com/ml-explore/mlx-swift) - Apple machine learning
- [llama.cpp](https://github.com/ggerganov/llama.cpp) - LLM inference
- [Stable Diffusion](https://github.com/apple/ml-stable-diffusion) - Image generation
- [Sparkle](https://sparkle-project.org) - App updates

Special thanks to all contributors and the Swift/AI communities.

---

**Ready to get started?** [Download SAM](https://github.com/SyntheticAutonomicMind/SAM/releases) and experience AI that respects your privacy while getting real work done.
