# AGENTS.md - SAM Project Guide

SAM (Synthetic Autonomic Mind) is a native macOS AI assistant built with Swift and SwiftUI. This guide provides essential information for all AI coding agents (CLIO, Cursor, Aider, GitHub Copilot, etc.).

## Quick Facts

- **Language:** Swift 6.0+ (strict concurrency mode enabled)
- **Platform:** macOS 14.0+, Apple Silicon (arm64) preferred, Intel support secondary
- **Build System:** Swift Package Manager (SPM) + Makefile
- **Architecture:** Modular, actor-based concurrency, privacy-first design
- **Testing:** XCTest framework, CI/CD via GitHub Actions
- **Repository:** https://github.com/SyntheticAutonomicMind/SAM
- **License:** GPL-3.0-only

---

## Setup Commands

### Prerequisites

- macOS 14.0+ (development on macOS 15.0+)
- Xcode 14.0+ with Swift 6.0+
- Command line tools: `xcode-select --install`
- ccache (optional, speeds up builds): `brew install ccache`

### Initial Setup

```bash
# Clone with submodules (required for llama.cpp)
git clone --recursive https://github.com/SyntheticAutonomicMind/SAM.git
cd SAM

# First build automatically builds llama.cpp framework
make build-debug
```

### Build Commands

```bash
# Debug build (faster, includes debug symbols)
make build-debug

# Release build (optimized for production)
make build-release

# Development release (auto-increments -dev.N)
make build-dev

# Clean all build artifacts
make clean

# Build only llama.cpp framework (macOS only)
make llamacpp
```

### Run Commands

```bash
# Run debug build
.build/Build/Products/Debug/SAM.app/Contents/MacOS/SAM

# Run release build
.build/Build/Products/Release/SAM.app/Contents/MacOS/SAM

# Open in Finder
open .build/Build/Products/Debug/SAM.app
```

### Test Commands

```bash
# Run all unit tests
swift test

# Run specific test suite
swift test --filter MyTestSuite

# Run all tests (unit + e2e)
./Tests/run_all_tests.sh

# Run MCP API tests
./Tests/mcp_api_tests.sh

# Run tests like CI/CD pipeline
./scripts/test_like_pipeline.sh
```

---

## Code Style & Conventions

### SPDX License Headers (MANDATORY)

ALL Swift files must begin with:
```swift
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)
```

### Naming Conventions

- **Classes/Structs/Enums:** `PascalCase` (e.g., `ConversationManager`, `ModelState`)
- **Functions/Variables:** `camelCase` (e.g., `loadModel()`, `conversationHistory`)
- **Constants:** `camelCase`, NOT `SCREAMING_SNAKE_CASE` (e.g., `let maxTokens = 2048`)
- **Protocols:** Descriptive names ending in `Protocol` when needed (e.g., `ToolRegistryProtocol`)
- **Actors:** `PascalCase` with `Actor` suffix when ambiguous (e.g., `ModelLoadingActor`)

### Comments & Documentation

- **Documentation comments:** `///` (shown in Xcode Quick Help)
- **Implementation comments:** `//` (explain WHY, not WHAT)
- **Section markers:** `// MARK: -` to organize code sections
- **Document intent:** Code should be self-documenting; comments explain decisions

### Logging

Use `swift-log` Logger (NEVER `print()` or `NSLog()`):
```swift
private let logger = Logger(label: "com.sam.modulename")

logger.debug("Debug message")
logger.info("Info message")
logger.warning("Warning message")
logger.error("Error message")
```

Logger label format: `com.sam.<module>` (e.g., `com.sam.orchestrator`, `com.sam.conversation`)

---

## Swift 6 Concurrency (CRITICAL - Non-Negotiable)

SAM uses **Swift 6 strict concurrency checking**. All code MUST follow these rules:

### Rules

1. **Sendable Conformance Required**
   - All types crossing actor boundaries must conform to `Sendable`
   - Use `@unchecked Sendable` ONLY when safe, with documentation

2. **MainActor Isolation for UI**
   - All SwiftUI views must be `@MainActor`
   - All ViewModels must be `@MainActor`
   - NSAttributedString operations MUST run on MainActor

3. **Capture Before Crossing Actor Boundaries**
   ```swift
   // ❌ BAD
   await withTaskGroup { group in
       group.addTask { await self.property.doSomething() }
   }
   
   // ✅ GOOD
   let property = self.property
   await withTaskGroup { group in
       group.addTask { await property.doSomething() }
   }
   ```

4. **Expected Build Results**
   - **0 errors** (always)
   - **~211 warnings** (Sendable-related, non-blocking, acceptable)
   - Run `make build-debug` to verify locally
   - Run `./scripts/test_like_pipeline.sh` to simulate CI/CD

### Common Patterns

See `project-docs/SWIFT6_CONCURRENCY_MIGRATION.md` for:
- Wrapper types for non-Sendable dictionaries
- `nonisolated(unsafe)` safe usage
- Capture patterns in loops
- Custom type erasure for Sendable compliance

---

## Project Structure

### Source Modules

```
Sources/
├── SAM/
│   ├── main.swift - Entry point, AppDelegate
│   └── App.swift - SwiftUI App definition
├── ConversationEngine/         - Core conversation system, memory, database
│   ├── ConversationManager.swift
│   ├── MemorySystem/
│   ├── Database/ (SQLite schema, queries)
│   └── Streaming/ (Response streaming)
├── MLXIntegration/             - Local model inference (Apple Silicon)
│   ├── ModelManager.swift
│   ├── MLXSession.swift
│   └── Tokenization/
├── UserInterface/              - SwiftUI components and views
│   ├── MainWindow.swift
│   ├── ConversationView.swift
│   ├── SettingsView.swift
│   └── Components/
├── ConfigurationSystem/        - App preferences, settings
│   ├── PreferencesManager.swift
│   ├── AppConfig.swift
│   └── PropertiesStorage/
├── APIFramework/               - Multi-provider support, orchestration
│   ├── APIProvider.swift (protocol)
│   ├── Providers/ (OpenAI, Anthropic, DeepSeek, GitHub Copilot)
│   ├── AgentOrchestrator.swift (multi-step workflows)
│   └── ToolCallExtractor.swift
├── MCPFramework/               - Model Context Protocol tools
│   ├── MCPTool.swift (protocol)
│   ├── Tools/ (14 tools, 46+ operations)
│   ├── ToolRegistry.swift
│   └── ToolResult.swift
├── SharedData/                 - Shared types, thread-safe storage
│   ├── SharedTopics.swift
│   ├── Storage.swift
│   └── Locking/
├── StableDiffusionIntegration/ - Local image generation
│   ├── ImageGenerator.swift
│   ├── ModelDownloader.swift
│   └── StyleManager.swift
├── Training/                   - LoRA model fine-tuning
│   ├── LoRATrainer.swift
│   ├── DataPreparation.swift
│   └── TrainingConfig.swift
└── VoiceFramework/             - Speech recognition, TTS, wake word
    ├── SpeechRecognizer.swift
    ├── TextToSpeech.swift
    └── WakeWordDetector.swift
```

### Important Files

- **Package.swift** - SPM manifest (dependencies, targets)
- **Info.plist** - App metadata (version, bundle ID, entitlements)
- **Makefile** - Build automation, llama.cpp, signing
- **SAM.entitlements** - Sandbox permissions
- **BUILDING.md** - Comprehensive build instructions
- **CONTRIBUTING.md** - Contribution guidelines
- **VERSIONING.md** - Version scheme and release process

### External Dependencies

- **external/llama.cpp/** - Git submodule for local model support (macOS only)
- **external/ml-stable-diffusion/** - Apple's image generation
- **.github/workflows/** - CI/CD automation (build, test, release)

---

## Testing Instructions

### Test Structure

```
Tests/
├── APIFrameworkTests/          - Provider integration, orchestration
├── ConfigurationSystemTests/   - Settings, preferences
├── ConversationEngineTests/    - Conversation, memory, database
├── MCPFrameworkTests/          - Tool registry, tool execution
├── TrainingTests/              - LoRA training
├── UserInterfaceTests/         - UI components
├── SecurityFrameworkTests/     - Security operations
├── e2e/                        - End-to-end integration
├── test_workspace/             - Test data directory
├── run_all_tests.sh            - Master test runner
├── mcp_api_tests.sh            - MCP API integration tests
└── KNOWN_ISSUES.md             - Known test issues
```

### Running Tests

```bash
# All unit tests
swift test

# Specific suite
swift test --filter APIFrameworkTests

# With verbose output
swift test --verbose

# All tests (unit + e2e)
./Tests/run_all_tests.sh

# MCP API tests
./Tests/mcp_api_tests.sh

# Like CI/CD pipeline
./scripts/test_like_pipeline.sh
```

### Coverage Requirements

- New features MUST have tests
- Tests must pass in CI/CD (GitHub Actions)
- Use `XCTest` framework
- Mock external dependencies (network, file system)

### Test Requirements

- Tests run on macOS 14.0+
- No external dependencies required
- Tests should be deterministic and fast
- Test data in `Tests/test_workspace/`

---

## CI/CD & Release

### GitHub Actions Workflows

- **.github/workflows/ci.yml** - Build and test on every push
- **.github/workflows/release.yml** - Build, sign, notarize, distribute
- **.github/workflows/nightly-dev.yml** - Nightly development builds
- **.github/workflows/update-homebrew-cask.yml** - Auto-update Homebrew cask

### Version Scheme

- **Format:** `YYYYMMDD.RELEASE[-dev.BUILD]`
- **Example:** `20260127.1` (stable), `20260127.1-dev.3` (dev)
- **File:** `Info.plist` (`CFBundleShortVersionString`)

### Release Types

1. **Stable Releases**
   - Version: `YYYYMMDD.RELEASE`
   - Published as GitHub releases
   - Distributed via Homebrew and automatic updates

2. **Development Releases**
   - Version: `YYYYMMDD.RELEASE-dev.BUILD`
   - Published as GitHub pre-releases
   - Opt-in via Preferences -> "Receive development updates"

---

## Commit Message Format (Conventional Commits)

All commits MUST follow Conventional Commits format:

```
<type>(<scope>): <subject>

[optional body]

[optional footer]
```

### Types

- `feat` - New feature
- `fix` - Bug fix
- `refactor` - Code refactoring (no functional changes)
- `docs` - Documentation changes
- `test` - Test additions/updates
- `chore` - Maintenance (dependencies, build config)
- `perf` - Performance improvements
- `style` - Code style changes (formatting)
- `ci` - CI/CD changes

### Scopes

- `ui` - User interface changes
- `api` - API provider implementations
- `mcp` - MCP framework and tools
- `conversation` - Conversation management
- `config` - Configuration system
- `build` - Build system and dependencies
- `voice` - Voice framework
- `training` - Model training
- `image` - Image generation
- `memory` - Memory and LTM

### Examples

```bash
git commit -m "feat(mcp): Add web scraping tool with structured data extraction"
git commit -m "fix(ui): Prevent toolbar overflow on narrow windows"
git commit -m "refactor(api): Extract streaming logic into separate service"
git commit -m "docs(training): Add LoRA fine-tuning guide"
```

---

## Key Development Workflows

### Adding a New Tool to MCP Framework

1. Create file in `Sources/MCPFramework/Tools/MyTool.swift`
2. Implement `MCPTool` protocol
3. Register in `UniversalToolRegistry`
4. Add tests in `Tests/MCPFrameworkTests/`
5. Document in tool's docstring
6. Add entry to CHANGELOG

**Important:** If your tool needs to access SAM data (system prompts, mini-prompts, settings), access the manager directly (e.g., `SystemPromptManager.shared`) instead of calling the HTTP API. Tools run in the same process, so direct access is simpler and doesn't require authentication.

### Adding Per-Conversation UI State (Panel, Setting, etc.)

When adding UI state that should persist per conversation:

1. **ConversationSettings struct** (`ConversationModel.swift`):
   - Add property to struct (e.g., `public var showingMyPanel: Bool`)
   - Add to init parameters with default value
   - Add to `CodingKeys` enum
   - Add to decoder with `decodeIfPresent` and default

2. **ChatWidget integration** (`ChatWidget.swift`):
   - Add `@State private var showingMyPanel = false`
   - Add `.onChange(of: showingMyPanel)` handler calling `savePanelState(panel: "mypanel", value: newValue)`
   - Add `case "mypanel":` to `savePanelState` switch
   - Add `showingMyPanel = conversation.settings.showingMyPanel` in `syncWithActiveConversation()`
   - Add `conversation.settings.showingMyPanel = showingMyPanel` in `saveUISettings()`

3. **Important:** SwiftUI's `onChange` doesn't fire when value is already set before view loads. Always ALSO set up state in `onAppear` for initial load.

### Adding a New AI Provider

1. Create provider in `Sources/APIFramework/Providers/MyProvider.swift`
2. Implement `APIProvider` protocol
3. Handle streaming responses
4. Add tests with mock responses
5. Register in `ProviderRegistry`

### Updating Dependencies

```bash
# Update SPM dependencies
swift package update

# Check for updates
swift package describe

# Pin problematic versions in Package.swift as needed
```

### Building for Distribution

```bash
# Create signed, notarized DMG
make distribute

# Outputs:
# - dist/SAM-{VERSION}.dmg (installer)
# - dist/SAM-{VERSION}.zip (update archive)
# - Updated appcast.xml (for Sparkle updates)
```

---

## Privacy & Security

- **NO telemetry, NO tracking by default**
- All conversations stored locally in SQLite
- API credentials stored in UserDefaults (consider KeychainManager for sensitive keys)
- Local models run entirely offline (MLX, llama.cpp)
- Cloud providers (OpenAI, Anthropic, etc.) are opt-in only

### Entitlements

See `SAM.entitlements` for:
- File system access requirements
- Network access for API providers
- Microphone access for voice
- Camera access (if image analysis needed)

---

## Common Issues & Solutions

### Build Fails with "llama.cpp not found"

```bash
# Ensure submodules are initialized
git submodule update --init --recursive

# Rebuild llama.cpp
make clean llamacpp

# Full rebuild
make build-debug
```

### Swift 6 Concurrency Errors

- See `project-docs/SWIFT6_CONCURRENCY_MIGRATION.md`
- Check for Actor boundaries
- Verify Sendable conformance
- Capture values before crossing async boundaries

### Tests Fail with Path Issues

- Ensure `Tests/test_workspace/` exists
- Run tests from project root: `cd SAM && swift test`
- Check file permissions: `chmod -R 755 Tests/`

### DMG Creation Fails

```bash
# Ensure release build exists
make build-release

# Check permissions
ls -la .build/Build/Products/Release/SAM.app

# Try manually
make create-dmg
```

---

## Resources & Documentation

- **Website:** https://www.syntheticautonomicmind.org
- **GitHub:** https://github.com/SyntheticAutonomicMind/SAM
- **Issues:** https://github.com/SyntheticAutonomicMind/SAM/issues
- **Discussions:** GitHub Discussions (for questions)
- **Internal Docs:** `project-docs/` directory
- **Build Guide:** `BUILDING.md`
- **Contributing:** `CONTRIBUTING.md`
- **Versioning:** `VERSIONING.md`

---

## Questions?

If you're stuck:
1. Check existing issue tracker
2. Review `project-docs/` for architecture notes
3. Look at similar code patterns
4. Read the detailed comments in source files
5. Check Tests for usage examples

---

*This guide is maintained alongside the SAM codebase and updated with each major release.*
