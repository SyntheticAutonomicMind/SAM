# SAM (Synthetic Autonomic Mind) - CLIO Project Instructions

**Project Methodology:** The Unbroken Method for Human-AI Collaboration

## CRITICAL: READ FIRST BEFORE ANY WORK

### The Unbroken Method (Core Principles)

This project follows **The Unbroken Method** for human-AI collaboration. This isn't just project style—it's the core operational framework.

**The Seven Pillars:**

1. **Continuous Context** - Never break the conversation. Maintain momentum through collaboration checkpoints.
2. **Complete Ownership** - If you find a bug, fix it. No "out of scope."
3. **Investigation First** - Read code before changing it. Never assume.
4. **Root Cause Focus** - Fix problems, not symptoms.
5. **Complete Deliverables** - No partial solutions. Finish what you start.
6. **Structured Handoffs** - Document everything for the next session.
7. **Learning from Failure** - Document mistakes to prevent repeats.

**If you skip this, you will violate the project's core methodology.**

---

## Project Overview

**SAM (Synthetic Autonomic Mind)** is a native macOS AI assistant built with Swift and SwiftUI. It provides:
- Multi-AI provider support (OpenAI, Anthropic, GitHub Copilot, DeepSeek, local MLX/llama.cpp models)
- Local image generation with Stable Diffusion
- Voice control with "Hey SAM" wake word
- Document intelligence (PDF, Word, Excel, text files)
- Semantic memory and conversation search
- MCP (Model Context Protocol) framework for autonomous agents with 14+ integrated tools
- Custom model training with LoRA fine-tuning
- Remote access via SAM-Web (browser-based interface)
- 100% privacy-first architecture (data stays on your Mac)

**Repository:** https://github.com/SyntheticAutonomicMind/SAM  
**Website:** https://www.syntheticautonomicmind.org

---

## Technology Stack

### Languages & Frameworks
- **Primary Language:** Swift 6.0+ (strict concurrency mode enabled)
- **UI Framework:** SwiftUI (native macOS, no UIKit/AppKit unless unavoidable)
- **Platform:** macOS 14.0+ (development on macOS 15.0+)
- **Build System:** Swift Package Manager (SPM) + Makefile
- **Architecture:** Apple Silicon (arm64) optimized, Intel support

### Key Dependencies
- **MLX Swift** - Apple Silicon ML acceleration (local model inference)
- **mlx-swift-lm** - Language models with MLX
- **swift-transformers** - Tokenization and model support
- **ml-stable-diffusion** - Apple's Stable Diffusion for image generation
- **llama.cpp** - Local model support (XCFramework, built via Makefile)
- **Vapor** - HTTP server for OpenAI-compatible API
- **SQLite.swift** - Conversation and memory database
- **Sparkle** - Automatic updates
- **swift-markdown** - AST-based markdown parsing
- **ZIPFoundation** - Office document extraction (DOCX, XLSX)
- **AsyncHTTPClient** - HTTP networking
- **swift-log** - Structured logging

### Module Structure
```
SAM (executable)
├── ConversationEngine    - Core conversation system, memory, database
├── MLXIntegration       - MLX and model management
├── UserInterface        - SwiftUI views and UI components
├── ConfigurationSystem  - App preferences, config management
├── APIFramework         - OpenAI-compatible server, providers, agent orchestration
├── MCPFramework         - Model Context Protocol tools (14 tools, 46+ operations)
├── SharedData           - Shared topics, storage, locking
├── StableDiffusionIntegration - Image generation
├── Training             - LoRA model training
└── VoiceFramework       - Speech recognition, TTS, wake word
```

---

## Swift 6 Concurrency (CRITICAL)

SAM uses **Swift 6 strict concurrency checking**. All code MUST be concurrency-safe.

### Non-Negotiable Rules

1. **Sendable Conformance Required**
   - All types crossing actor boundaries must conform to `Sendable`
   - Use `@unchecked Sendable` ONLY when safe (immutable after init, JSON-serializable dictionaries)
   - Document why `@unchecked Sendable` is safe in comments

2. **MainActor Isolation for UI**
   - All SwiftUI views and ViewModels must be `@MainActor`
   - NSAttributedString operations MUST run on MainActor (not Sendable)
   - AppKit/UIKit operations require MainActor

3. **Capture Before Crossing Actor Boundaries**
   ```swift
   // BAD - property access across actor boundary
   await withTaskGroup { group in
       group.addTask {
           await self.property.doSomething()  // ❌ Error
       }
   }
   
   // GOOD - capture before async
   let property = self.property  // Capture synchronously
   await withTaskGroup { group in
       group.addTask {
           await property.doSomething()  // ✅ OK
       }
   }
   ```

4. **SQLite Expression Helpers**
   - Use `column("name", String.self)` instead of `Expression<String>("name")`
   - Import helpers from `ConversationEngine/SQLiteHelpers.swift`

5. **Expected Build Results**
   - **0 errors** (always)
   - **~211 warnings** (Sendable-related, non-blocking, acceptable)
   - Use `make build-debug` to verify locally
   - Use `./scripts/test_like_pipeline.sh` to simulate CI/CD

### Common Patterns

**Pattern 1: Wrapper for Non-Sendable Dictionaries**
```swift
private struct SendableParams: @unchecked Sendable {
    let value: [String: Any]  // Safe if only JSON types
}

let params = SendableParams(value: toolCall.arguments)
await withTaskGroup { group in
    group.addTask { @Sendable in
        await execute(params: params.value)
    }
}
```

**Pattern 2: nonisolated(unsafe) for Safe Non-Sendable**
```swift
class ToolManager {
    nonisolated(unsafe) private let toolRegistry: [String: Tool]
    
    // Safe because toolRegistry is immutable after init
    init(tools: [String: Tool]) {
        self.toolRegistry = tools
    }
}
```

**Pattern 3: Capture Before Loops**
```swift
// BAD
for item in items {
    await process(options: self.options)  // ❌ Capture in loop
}

// GOOD
let options = self.options  // Capture once
for item in items {
    await process(options: options)  // ✅ OK
}
```

**See:** `project-docs/SWIFT6_CONCURRENCY_MIGRATION.md` for complete migration history.

---

## Code Style & Conventions

### File Headers
All Swift files MUST include SPDX headers:
```swift
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)
```

### Naming Conventions
- **Classes/Structs/Enums:** `PascalCase`
- **Functions/Variables:** `camelCase`
- **Constants:** `camelCase` (not SCREAMING_SNAKE_CASE)
- **Protocols:** Descriptive names ending in `Protocol` when needed (e.g., `ToolRegistryProtocol`)
- **Actors:** `PascalCase` with `Actor` suffix when ambiguous (e.g., `ModelLoadingActor`)

### Comments
- Use `///` for documentation comments (shown in Xcode Quick Help)
- Use `//` for implementation notes
- Use `// MARK: -` to organize code sections
- Document WHY, not WHAT (code should be self-documenting)

### Logging
- Use `swift-log` Logger (not `print()`)
- Logger label format: `com.sam.<module>` (e.g., `com.sam.orchestrator`)
- Log levels: `.trace`, `.debug`, `.info`, `.notice`, `.warning`, `.error`, `.critical`

---

## Build System

### Makefile Targets (Primary Interface)
```bash
make build-debug          # Debug build (faster, includes debug symbols)
make build-release        # Release build (optimized for production)
make build-dev            # Development release (auto-increments -dev.N suffix)
make clean               # Clean build artifacts
make test                # Run all tests
make sign-release        # Sign release build (requires APPLE_DEVELOPER_ID)
make llamacpp            # Build llama.cpp XCFramework
```

### Development Workflow
1. **First Build:** `make build-debug` (builds llama.cpp + SAM)
2. **Incremental:** `make build-debug` (only rebuilds changed code)
3. **Clean Build:** `make clean && make build-debug`
4. **Test Like CI:** `./scripts/test_like_pipeline.sh`

### Important Files
- `Package.swift` - Swift package manifest (dependencies, targets)
- `Makefile` - Build automation (llama.cpp, bundling, signing)
- `Info.plist` - App metadata, version, entitlements
- `BUILDING.md` - Comprehensive build instructions
- `CONTRIBUTING.md` - Contribution guidelines

---

## Testing

### Test Structure
```
Tests/
├── APIFrameworkTests/        - API provider, orchestrator tests
├── ConfigurationSystemTests/ - Config management tests
├── ConversationEngineTests/  - Conversation, memory tests
├── MCPFrameworkTests/        - MCP tool tests
├── TrainingTests/            - LoRA training tests
├── UserInterfaceTests/       - UI component tests
├── e2e/                      - End-to-end integration tests
└── run_all_tests.sh          - Master test runner
```

### Running Tests
```bash
swift test                    # All unit tests
swift test --filter MyTests   # Specific test suite
./Tests/run_all_tests.sh      # All tests (unit + e2e)
./Tests/mcp_api_tests.sh      # MCP API integration tests
```

### Test Requirements
- All new features MUST have tests
- Tests must pass in CI/CD (GitHub Actions)
- Use `XCTest` framework
- Mock external dependencies (network, file system when appropriate)

---

## CI/CD

### GitHub Actions Workflows
- `.github/workflows/ci.yml` - Build and test on every push
- `.github/workflows/release.yml` - Release builds and distribution
- `.github/workflows/nightly-dev.yml` - Nightly development builds

### CI Requirements
- **Must pass:** Build succeeds with 0 errors
- **Acceptable:** ~211 Sendable-related warnings
- **Must pass:** All tests pass
- **Must pass:** Code signing succeeds (release only)

---

## MCP Framework (Critical Component)

SAM's autonomous agent capabilities are powered by the **MCP (Model Context Protocol) Framework**.

### Tool Categories (14 tools, 46+ operations)
1. **file_operations** - Read, write, search, manage files
2. **version_control** - Git operations
3. **terminal_operations** - Execute shell commands safely
4. **memory_operations** - Session memory and LTM (Long-Term Memory)
5. **web_operations** - Fetch URLs, web search
6. **todo_operations** - Task tracking for multi-step workflows
7. **code_intelligence** - Symbol search, code analysis
8. **user_collaboration** - Request user input during workflows

### Agent Orchestration
- **AgentOrchestrator** (`Sources/APIFramework/AgentOrchestrator.swift`) - Multi-step autonomous workflow engine
- Implements VS Code Copilot's tool calling loop pattern
- YaRN context processor for intelligent context management (128M token profile)
- Tool result storage for large outputs (persisted to disk)
- Smart loop detection and context pruning

### Tool Development
- Tools are defined in `Sources/MCPFramework/Tools/`
- Each tool implements `MCPTool` protocol
- Tools are registered in `UniversalToolRegistry`
- Tool calls are extracted by `ToolCallExtractor` (supports OpenAI, Anthropic, Qwen, Hermes formats)

---

## Versioning & Releases

### Version Scheme
- **Format:** `YYYYMMDD.RELEASE[-dev.BUILD]`
- **Example:** `20260127.1` (stable), `20260127.1-dev.3` (development)
- **File:** `Info.plist` (`CFBundleShortVersionString`)

### Release Types
1. **Stable Releases**
   - Version: `YYYYMMDD.RELEASE`
   - Published as GitHub releases
   - Listed in `appcast.xml`
   - All users receive these

2. **Development Releases**
   - Version: `YYYYMMDD.RELEASE-dev.BUILD`
   - Published as GitHub pre-releases
   - Listed in `appcast-dev.xml`
   - Opt-in via Preferences -> "Receive development updates"

### Creating Releases
```bash
# Development release
make build-dev              # Auto-increments -dev.N suffix
./scripts/sign-and-notarize.sh
# Create GitHub pre-release
make appcast-dev            # Update development appcast

# Stable release
./scripts/increment-version.sh
make build-release
./scripts/sign-and-notarize.sh
# Create GitHub release
# Update appcast.xml manually
```

**See:** `VERSIONING.md` for complete details.

---

## Collaboration Checkpoint Discipline (MANDATORY)

**Use collaboration checkpoints at these key moments:**

| Checkpoint | When | MANDATORY |
|-----------|------|-----------|
| **Session Start** | Multi-step work OR recovering from handoff | YES - Present plan BEFORE starting |
| **After Investigation** | Before making any code/config changes | YES - Get approval first |
| **Before Commit** | After implementation complete | YES - Show results |
| **Session End** | Work complete or blocked | YES - Summary & handoff |

### Session Start Checkpoint (MANDATORY)
When user provides multi-step request OR you're recovering a previous session:
1. STOP - do NOT start implementation yet
2. Call `user_collaboration` with your plan:
   - "Based on your request to [X], here's my plan:"
   - "1) [investigation step], 2) [implementation step], 3) [verification step]"
   - "Proceed with this approach?"
3. WAIT for user response
4. ONLY THEN begin work

### After Investigation Checkpoint (MANDATORY)
After reading files, searching code, understanding context:
1. STOP - do NOT start making changes yet
2. Call `user_collaboration` with findings:
   - "Here's what I found: [summary]"
   - "I'll make these changes: [specific files + what will change]"
   - "Proceed?"
3. WAIT for user response
4. ONLY THEN make changes

### When You CAN Skip Checkpoints
- Single-line code explanations
- Reading files (non-destructive)
- Searching codebase (investigation)
- Answering questions (no implementation)
- User explicitly says "just do it" or "don't ask, just fix it"

---

## Core Workflow

```
1. Read code first (investigation)
2. Use collaboration tool (get approval)
3. Make changes (implementation)
4. Test thoroughly (verify)
5. Commit with clear message (handoff)
```

---

## Tool-First Approach (MANDATORY)

**NEVER describe what you would do - DO IT:**
- ❌ WRONG: "I'll create a file with the following content..."
- ✅ RIGHT: [calls file_operations to create the file]

- ❌ WRONG: "I'll search for that pattern in the codebase..."
- ✅ RIGHT: [calls grep_search to find the pattern]

**IF A TOOL EXISTS TO DO SOMETHING, YOU MUST USE IT:**
- File changes → Use `file_operations`, NEVER print code blocks
- Terminal commands → Use `terminal_operations`, NEVER print commands for user to run
- Git operations → Use `version_control`
- Multi-step tasks → Use `todo_operations` to track progress
- Code search → Use `grep_search` or `semantic_search`
- Web research → Use `web_operations`

---

## Investigation-First Principle

**Before making changes, understand the context:**
1. Read files before editing them
2. Check current state before making changes (git status, file structure)
3. Search for patterns to understand codebase organization
4. Use `semantic_search` when you don't know exact filenames/strings

**Don't assume - verify:**
- Don't assume how code works - read it
- Don't guess file locations - search for them
- Don't make changes blind - investigate first

---

## Error Recovery - 3-Attempt Rule

**When a tool call fails:**
1. **Retry** with corrected parameters or approach
2. **Try alternative** tool or method
3. **Analyze root cause** - why are attempts failing?

**After 3 attempts:**
- Report specifics: what you tried, what failed, what you need
- Suggest alternatives or ask for clarification
- Don't just give up - offer options

---

## Session Handoff Procedures (MANDATORY)

When ending a session, **ALWAYS** create a properly structured handoff directory:

```
ai-assisted/YYYYMMDD/HHMM/
├── CONTINUATION_PROMPT.md  [MANDATORY] - Next session's complete context
├── AGENT_PLAN.md           [MANDATORY] - Remaining priorities & blockers
├── CHANGELOG.md            [OPTIONAL]  - User-facing changes (if applicable)
└── NOTES.md                [OPTIONAL]  - Additional technical notes
```

### NEVER COMMIT Handoff Files

**[CRITICAL] BEFORE EVERY COMMIT:**

```bash
# ALWAYS verify no handoff files are staged:
git status

# If any `ai-assisted/` files appear:
git reset HEAD ai-assisted/

# Then commit only actual code/docs:
git add -A && git commit -m "type(scope): description"
```

**Why:** Handoff documentation contains internal session context that should NEVER be in the public repository. This is a **HARD REQUIREMENT**.

### CONTINUATION_PROMPT.md (MANDATORY)

**Purpose:** Provides complete standalone context for the next session to start immediately.

**Minimum Content:**
- What Was Accomplished (completed tasks list)
- Current State (code changes, test results, git activity)
- What's Next (Priority 1, 2, 3 tasks with specific details)
- Key Discoveries & Lessons Learned
- Context for Next Developer (architecture notes, known issues)
- Complete File List (modified and new files with paths)

### AGENT_PLAN.md (MANDATORY)

**Purpose:** Remaining work plan with priorities and blockers.

**Minimum Content:**
- Current Blockers (specific issues preventing progress)
- Immediate Next Steps (actionable tasks)
- Medium-term Goals (upcoming features)
- Open Questions (decisions needed from user)

---

## Commit Message Format (Conventional Commits)

**Format:**
```
<type>(<scope>): <subject>

[optional body]

[optional footer]
```

**Types:**
- `feat`: New feature
- `fix`: Bug fix
- `refactor`: Code refactoring (no functional changes)
- `docs`: Documentation changes
- `test`: Adding or updating tests
- `chore`: Maintenance (dependencies, build config)
- `perf`: Performance improvements
- `style`: Code style changes (formatting)

**Scopes:**
- `ui`: User interface changes
- `api`: API provider implementations
- `mcp`: MCP framework and tools
- `conversation`: Conversation management
- `config`: Configuration system
- `build`: Build system and dependencies
- `voice`: Voice framework (wake word, TTS)
- `training`: Model training
- `image`: Image generation
- `memory`: Memory and LTM

**Examples:**
```bash
git commit -m "feat(mcp): Add web scraping tool with structured data extraction"
git commit -m "fix(ui): Prevent toolbar overflow on narrow windows"
git commit -m "refactor(api): Extract streaming logic into separate service"
```

---

## Project-Specific Notes

### Privacy First
- **NO telemetry, NO tracking, NO cloud data by default**
- API credentials stored locally in UserDefaults (consider KeychainManager for sensitive keys)
- All conversations stored in local SQLite database
- Local models run entirely offline (MLX, llama.cpp)
- Cloud providers (OpenAI, Anthropic) are opt-in only

### Performance Considerations
- Apple Silicon optimization is priority (arm64 Metal, MLX acceleration)
- Intel support is secondary but should remain functional
- MLX Metal library bundle must be embedded in app Resources
- Large language models require significant RAM (16GB+ recommended)
- Image generation (Stable Diffusion) is memory-intensive

### Known Limitations
- macOS 14.0+ only (no iOS, no cross-platform)
- Apple Silicon strongly recommended (Intel has limited ML acceleration)
- Local models require significant disk space (10GB+ for larger models)
- Voice features require microphone permissions
- File access requires proper sandbox entitlements

### Critical Files to Never Break
- `Info.plist` - Version, bundle ID, entitlements
- `Package.swift` - Dependencies, targets
- `Makefile` - Build system
- `SAM.entitlements` - Sandbox permissions
- `external/llama.cpp/` - Submodule (do not modify directly)

---

## Resources & Documentation

### Internal Documentation
- `BUILDING.md` - Build instructions
- `CONTRIBUTING.md` - Contribution guidelines
- `VERSIONING.md` - Version scheme and release process
- `RELEASE_NOTES.md` - User-facing release notes
- `project-docs/` - Architecture, migration guides
- `Tests/KNOWN_ISSUES.md` - Test suite known issues

### External Resources
- **Website:** https://www.syntheticautonomicmind.org
- **Repository:** https://github.com/SyntheticAutonomicMind/SAM
- **Issue Tracker:** https://github.com/SyntheticAutonomicMind/SAM/issues
- **Support:** https://www.patreon.com/fewtarius

---

## Quick Reference

### Common Commands
```bash
# Build
make build-debug
make build-release
make clean

# Test
swift test
./Tests/run_all_tests.sh

# Run
.build/Build/Products/Debug/SAM.app/Contents/MacOS/SAM

# Version
./scripts/increment-version.sh        # Stable release
./scripts/increment-dev-version.sh    # Dev release

# Sign & Notarize
export APPLE_DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
./scripts/sign-and-notarize.sh
```

### File Locations
- **Source Code:** `Sources/`
- **Tests:** `Tests/`
- **Resources:** `Resources/`
- **Build Output:** `.build/Build/Products/`
- **External Dependencies:** `external/`
- **Scripts:** `scripts/`
- **Documentation:** `project-docs/`

---

## Remember

Your value is in:
1. **TAKING ACTION** - Not describing possible actions
2. **USING TOOLS** - Not explaining what tools could do
3. **COMPLETING WORK** - Not stopping partway through
4. **PROCESSING RESULTS** - Not just showing raw tool output

**The user expects an agent that DOES things, not a chatbot that TALKS about doing things.**

---

**This project follows The Unbroken Method. Maintain context, own the work, investigate first, fix root causes, deliver completely, handoff properly, and learn from failures.**
