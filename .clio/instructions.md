# SAM Project Instructions for CLIO

**Project:** SAM - Synthetic Autonomic Mind  
**Language:** Swift 6.0+, SwiftUI  
**Architecture:** Native macOS AI assistant with SwiftUI UI, local + cloud AI support  
**Build System:** Makefile-driven Swift Package Manager build  

---

## CRITICAL: READ FIRST BEFORE ANY WORK

### The Unbroken Method (Core Principles)

This project follows **The Unbroken Method** for human-AI collaboration. This isn't just project style—it's the core operational framework that enabled SAM's rapid development and ~99% build success rate.

**The Seven Pillars:**

1. **Continuous Context** - Never break the conversation. Maintain momentum through collaboration checkpoints using `user_collaboration` tool.
2. **Complete Ownership** - If you find a bug, fix it. No "out of scope." This includes documentation bugs, typos, and architectural issues.
3. **Investigation First** - Read code before changing it. Never assume. Search the codebase with `grep_search` and `semantic_search` before implementing.
4. **Root Cause Focus** - Fix problems, not symptoms. Ask "why?" until you reach the fundamental issue. Solve architecturally, not just locally.
5. **Complete Deliverables** - No partial solutions. No `TODO` comments or placeholders. Handle edge cases within scope. Finish what you start, completely.
6. **Structured Handoffs** - Document everything for continuation. The next session needs complete context.
7. **Learning from Failure** - Document mistakes to prevent repeats. Add anti-patterns to this file when discovered.

**If you skip this, you will violate the project's core methodology and break the collaboration framework.**

---

## COLLABORATION CHECKPOINT DISCIPLINE

**Use `user_collaboration` tool at EVERY key decision point. This is NOT optional.**

| Checkpoint | When | Tool Call | Purpose |
|-----------|------|-----------|---------|
| Session Start | Always, first thing | `user_collaboration("Session started...")` | Confirm context & plan |
| After Investigation | Before any implementation | `user_collaboration("Investigation complete...")` | Share findings, get approval |
| After Implementation | Before commit | `user_collaboration("Implementation complete...")` | Show results, verify with user |
| Session End | When work complete | `user_collaboration("Work complete...")` | Summary & handoff |

**CRITICAL RULES:**
- ALWAYS use `user_collaboration` with clear messaging
- WAIT for user response at checkpoints - they may request changes
- Between checkpoints: Investigation and reading are OK without asking
- Keep working until user explicitly stops you
- Never create analysis documents - checkpoint via collaboration tool instead

**[FAIL]** Create documentation/implementations without checkpointing  
**[OK]** Investigate freely, but checkpoint before committing changes

---

## Quick Start for NEW DEVELOPERS

### Before Touching Code

1. **Understand SAM's architecture:**
   ```bash
   cat README.md                          # Project overview
   cat ai-assisted/THE_UNBROKEN_METHOD.md # Methodology
   cat CONTRIBUTING.md                     # Contribution guide
   ls -la Sources/                        # See module structure
   ```

2. **Know the build system:**
   - All builds: Use `make build-debug` or `make clean`
   - NEVER use `swift build`, `swift run`, or `xcodebuild` directly
   - Build artifacts go to `.build/`
   - Syntax check: `swift build` output must show no errors

3. **Understand module organization:**
   - `Sources/SAM/` - Main executable entry point
   - `Sources/ConversationEngine/` - AI conversation management
   - `Sources/APIFramework/` - OpenAI-compatible API server
   - `Sources/MCPFramework/` - Tool execution framework (MCP protocol)
   - `Sources/UserInterface/` - SwiftUI components (NO multi-pane navigation)
   - `Sources/ConfigurationSystem/` - Settings & preferences
   - `Sources/MLXIntegration/` - Local model support (Apple Silicon optimization)
   - `Sources/StableDiffusionIntegration/` - Image generation
   - `Sources/Training/` - LoRA fine-tuning system
   - `Sources/VoiceFramework/` - Voice I/O
   - `Sources/SharedData/` - Shared utilities and data models

4. **Use the toolchain:**
   ```bash
   make build-debug                  # Build debug version
   make clean                        # Clean build artifacts
   git status                        # Always check before work
   git log --oneline -10             # Recent history
   ```

### Core Workflow

```
1. Read code first (investigation - grep_search, semantic_search, read files)
2. Checkpoint via user_collaboration (get approval for plan)
3. Make changes (implementation - use file_operations, terminal_operations)
4. Build and test (verify - make build-debug, run manual tests)
5. Commit with clear message (handoff - git commit)
```

---

## Key Directories & Files

### Core Modules
| Path | Purpose | Status | Size |
|------|---------|--------|------|
| `Sources/SAM/` | Main executable | Complete | Small |
| `Sources/ConversationEngine/` | Conversation management + memory | [OK] | 20 files |
| `Sources/APIFramework/` | OpenAI-compatible API | [OK] | 37 files |
| `Sources/MCPFramework/` | MCP tool protocol | [OK] | 22 files |
| `Sources/UserInterface/` | SwiftUI components | [MATURE] | 20 files |
| `Sources/ConfigurationSystem/` | Settings management | [OK] | 28 files |
| `Sources/MLXIntegration/` | Local model support | [ACTIVE] | 5 files |
| `Sources/StableDiffusionIntegration/` | Image generation | [OK] | 13 files |
| `Sources/Training/` | LoRA fine-tuning | [OK] | 14 files |
| `Sources/VoiceFramework/` | Voice I/O | [OK] | 10 files |
| `Sources/SharedData/` | Shared utilities | [OK] | 4 files |

### Important Files
| File | Purpose | Audience |
|------|---------|----------|
| `Package.swift` | Swift Package configuration | Developers |
| `Makefile` | Build automation | Developers |
| `README.md` | User-facing overview | Everyone |
| `CONTRIBUTING.md` | Contribution guidelines | Contributors |
| `.github/copilot-instructions.md` | Original Copilot instructions | Reference |
| `ai-assisted/THE_UNBROKEN_METHOD.md` | Unbroken Method full guide | Developers |

### Test Directories
| Path | Purpose |
|------|---------|
| `Tests/` | Unit and integration tests organized by module |
| `Tests/README.md` | Test documentation |
| `Tests/KNOWN_ISSUES.md` | Known test failures and issues |

### Development Notes
| Path | Purpose | Status |
|------|---------|--------|
| `ai-assisted/` | Session handoffs and context (DO NOT COMMIT) | [OK] |
| `scratch/` | Temporary development files | [OK] |
| `docs/` | User documentation (if exists) | [OK] |

---

## Architecture Overview

```
User Input (macOS UI or Remote)
    ↓
SwiftUI Frontend (UserInterface)
    ↓
Conversation Engine
    ├─ Conversation Management
    ├─ Message History (SQLite)
    └─ Context Management
    ↓
API Selection (Local MLX or Cloud)
    ↓
AI Model Response
    ↓
MCP Tool Detection (MCPFramework)
    ├─ File Operations
    ├─ Code Execution
    ├─ Web Research
    ├─ Image Generation (StableDiffusion)
    └─ Other Tools
    ↓
Tool Execution Results
    ↓
Response Formatting
    ↓
UI Rendering + Store in Memory
```

---

## Code Standards: MANDATORY

### Every Swift File Must Have

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2025 [Author] - SAM Project

import Foundation
import Logging

private let logger = Logger(label: "com.sam.ComponentName")

// MARK: - Class/Structure Definition

/// Brief description of the component
/// 
/// Longer description explaining purpose and behavior
public class ComponentName {
    // Implementation
}
```

### Logging: MANDATORY PATTERN

```swift
import Logging
private let logger = Logger(label: "com.sam.ComponentName")

// Use logger, NEVER print()
logger.info("Action completed")
logger.error("Error: \(error.localizedDescription)")
logger.debug("Detail value: \(debugValue)")

// WRONG - DO NOT DO THIS:
print("debug info")            // Not visible in logging
NSLog("message")               # Goes to system log, not structured
print("Some emoji: 🎨")        # No emojis in logs
```

### No Hardcoding, Use Configuration

```swift
// [CORRECT]
if let apiEndpoint = ConfigurationManager.shared.apiEndpoint {
    // Use dynamic configuration
}

// [WRONG]
let apiEndpoint = "http://localhost:8000"  // Hardcoded!
```

### Comments: Keep Them Accurate

```swift
// [CORRECT] - Explains WHY, not WHAT code does
// Using async/await to prevent UI blocking on large model loads
async let result = await model.loadWeights()

// [WRONG] - Code itself is clear, this adds no value
// Set result to the await result
let result = await someFunction()

// [WRONG] - Comment is out of sync with code
// This connects to the database  <-- But code actually calls an API!
let response = await apiClient.fetch()
```

### Error Handling

```swift
// [CORRECT] - Handle errors explicitly
do {
    let result = try await performAction()
} catch {
    logger.error("Failed to perform action: \(error.localizedDescription)")
    // Handle error appropriately
}

// [WRONG]
try? await performAction()  // Silent failure - bad for debugging!
```

---

## Build & Test Workflow

### Building SAM

**ALWAYS use Makefile:**
```bash
# Build debug version
make build-debug

# Clean build artifacts  
make clean

# Build and run tests
make test  # if available

# Check build status
swift build 2>&1 | grep -i error  # Should return nothing if clean
```

**NEVER use these directly:**
- ❌ `swift build` - May miss dependencies or configuration
- ❌ `swift run` - Incomplete build process
- ❌ `xcodebuild` - Not configured for this project
- ❌ `swiftc` directly - Bypass package manager

### Before Committing Changes

1. **Syntax check all modified files:**
   ```bash
   swift build 2>&1 | tee /tmp/build.log
   grep -i "error\|warning" /tmp/build.log
   # If any errors appear, fix them before committing
   ```

2. **Run relevant unit tests:**
   ```bash
   # If test target exists:
   swift test Tests/[ModuleName]Tests/
   ```

3. **Manual testing:**
   ```bash
   # Build and verify no runtime errors
   make build-debug
   # Test specific functionality manually if applicable
   ```

4. **Check for regressions:**
   ```bash
   # If prior builds were working, verify current state
   git status  # Check what changed
   git diff Sources/  # Review actual changes
   ```

### Testing Best Practices

- **Create tests for new features** in `Tests/[ModuleName]Tests/`
- **Update existing tests** if you change module behavior
- **Run full test suite** before major commits
- **Document failing tests** in `Tests/KNOWN_ISSUES.md` if unable to fix immediately

---

## Commit Workflow

### Commit Message Format

```
type(scope): brief description (50 chars max)

Problem: What was broken/incomplete/needed
Solution: How you fixed it
Testing: How you verified the fix
```

**Types:**
- `feat` - New feature
- `fix` - Bug fix
- `refactor` - Code reorganization without behavior change
- `docs` - Documentation changes
- `test` - Test additions/updates
- `perf` - Performance improvements
- `chore` - Build, dependencies, maintenance

**Example:**
```bash
git add -A
git commit -m "fix(conversation-engine): handle nil conversation gracefully

Problem: App crashes when conversation context is unexpectedly nil
Solution: Added nil check before accessing conversation properties
Testing: Verified app doesn't crash with corrupted conversation data"
```

### Before Committing: Checklist

- [ ] `swift build` produces no errors or warnings
- [ ] All modified files have proper headers (SPDX license)
- [ ] No hardcoded values (use ConfigurationSystem)
- [ ] All logging uses proper logger (not print/NSLog)
- [ ] Tests added/updated if behavior changed
- [ ] Commit message explains WHAT and WHY
- [ ] No `TODO`/`FIXME` comments in final code
- [ ] POD documentation updated if API changed
- [ ] **DO NOT COMMIT ai-assisted/** (session handoffs only for next dev)

### Files to NEVER Commit

**These are session handoff files - NEVER commit them:**
- `ai-assisted/` - All subdirectories and files
- `.clio/sessions/` - CLIO session state

**Verify before committing:**
```bash
git status
# Should NOT show: ai-assisted/ or .clio/sessions/

git diff --cached | grep -i "ai-assisted"
# Should return nothing

git commit -m "..."  # Safe to commit
```

---

## Anti-Patterns: NEVER DO THESE

| Anti-Pattern | Why | What To Do Instead |
|--------------|-----|-------------------|
| Use `swift build` directly | Misses Makefile configuration | `make build-debug` |
| Hardcode API endpoints/credentials | Not portable, security risk | Use `ConfigurationSystem` |
| `print()` for debugging | Not in structured logs | Use `logger.debug()` |
| Bare `try?` or `try!` | Silent failures make debugging impossible | Use `do/catch` with logging |
| Commit `ai-assisted/` files | Pollutes git history | Keep handoffs outside git |
| `TODO` in finished code | Technical debt marker | Finish implementation or file issue |
| Multi-pane SwiftUI navigation | Breaks single-pane design | Keep UI simple and focused |
| Assume configuration exists | App crashes on missing config | Always validate with optional binding |
| Skip error handling | App crashes on edge cases | Always handle errors explicitly |
| Modify production code without tests | Regressions go unnoticed | Write tests for new features |

---

## Development Tools & Commands

### Terminal Quick Reference

```bash
# Git operations
git status                      # Check what changed
git log --oneline -10           # Recent commits
git diff Sources/               # See exact changes
git branch -a                   # List branches

# Building
make build-debug                # Full debug build
make clean                      # Clean artifacts
swift build 2>&1 | head -50    # Check first 50 lines of build

# Searching code
git grep "function_name"        # Find function calls
grep -r "pattern" Sources/      # Search for pattern
find Sources/ -name "*.swift" | xargs grep "TODO"  # Find TODOs

# File operations
ls -la Sources/                 # List modules
wc -l Sources/**/*.swift        # Count lines
```

### Common Development Tasks

```bash
# When starting work
git status                      # Check current state
git log --oneline -5            # See recent work

# When investigating issues
git grep "error_text"           # Find error handling
git log --oneline -20 | grep relevant-word  # Search history
git blame Sources/File.swift    # See who changed what

# When ready to commit
git diff --cached               # Review staged changes
git status                      # Verify what's staged
git commit -m "type(scope): message"  # Commit

# After committing
git log --oneline -5            # Verify commit worked
git push origin branch-name     # Push if needed
```

---

## Investigation-First Principle

**Before making ANY changes, understand the context:**

1. **Read the relevant code files:**
   ```
   - Use file_operations to read the files you'll modify
   - Read dependencies to understand data flow
   - Don't assume how code works - verify it
   ```

2. **Search for patterns:**
   ```
   - grep_search for similar implementations
   - semantic_search to understand module organization
   - Look for existing solutions to your problem
   ```

3. **Check git history:**
   ```bash
   git log --oneline -20 Sources/RelevantModule/
   git blame Sources/RelevantModule/File.swift
   # Understand WHY code is structured this way
   ```

4. **Test your understanding:**
   ```
   - Create a small test to verify behavior
   - Run the app and observe real-world behavior
   - Ask yourself "why is it this way?" and verify the answer
   ```

5. **Checkpoint before implementing:**
   ```
   - Use user_collaboration tool to share findings
   - Propose specific changes based on investigation
   - Wait for user approval before implementing
   ```

**It's YOUR RESPONSIBILITY to gather context - use multiple tools repeatedly until you have enough information.**

---

## Complete Your Work

**What "complete" means:**
- Single task: Fully functional, tested, documented
- Multi-step task: ALL steps done, ALL items processed, outputs validated
- Bug fix: Root cause fixed, no partial solutions, verified working
- Feature: All requirements met, edge cases handled, tests included

**Before declaring complete:**
- Did I finish every step requested?
- Did I process ALL items (if batch operation)?
- Did I verify results match requirements?
- Are there any errors or partial completions?
- Did I checkpoint with user?

**Validation:**
- Build the code: `make build-debug` produces no errors
- Run tests if relevant
- Manually verify functionality
- Review commit messages for clarity
- Ensure documentation is updated

---

## Memory & Context for Next Session

When your session ends or you need to hand off work:

1. **Create structured handoff files in `ai-assisted/`:**
   ```
   - CONTINUATION_PROMPT.md - Full context for resuming
   - AGENT_PLAN.md - What work remains (if any)
   - IMPLEMENTATION_NOTES.md - How you solved it
   ```

2. **These files are NOT committed to git:**
   ```bash
   git status  # Should NOT list ai-assisted/
   ```

3. **Next developer reads these files to understand:**
   - What you accomplished
   - What remains to do
   - Why you made specific decisions
   - Known issues or gotchas

4. **Example handoff structure:**
   ```markdown
   # CONTINUATION_PROMPT.md
   
   ## Session Summary
   Worked on: [what you did]
   Status: [complete/in-progress/blocked]
   
   ## Current State
   - Build: [passing/failing]
   - Tests: [passing/failing/not run]
   - Git: [X commits made, all pushed]
   
   ## Next Steps (if any)
   1. [Specific next task]
   2. [Specific next task]
   
   ## Important Context
   - [What you learned]
   - [Gotchas to avoid]
   - [How to test your changes]
   ```

---

## Reference: SAM Features & Components

### Key Capabilities
- **Multi-Provider AI**: OpenAI, Claude, DeepSeek, local MLX models
- **Conversation Memory**: SQLite-backed storage with search
- **Document Import**: PDF, Word, Excel, text files
- **Web Research**: Browse and fetch URLs
- **Image Generation**: Stable Diffusion with LoRA support
- **Model Training**: Fine-tune with LoRA
- **Voice Support**: Input/output voice capabilities
- **Remote Access**: Web interface (SAM-Web)
- **Tool Execution**: MCP protocol for autonomous tool use

### Module Responsibilities
- **ConversationEngine** - Talk to AI, manage memory
- **APIFramework** - Serve OpenAI-compatible API
- **MCPFramework** - Execute tools autonomously
- **UserInterface** - macOS SwiftUI app
- **MLXIntegration** - Local model execution
- **StableDiffusionIntegration** - Image generation
- **Training** - LoRA fine-tuning
- **ConfigurationSystem** - Settings management

### Common Development Scenarios

**Adding a new AI provider:**
1. Research the API spec
2. Extend `APIFramework`
3. Add to `ConfigurationSystem`
4. Test with conversation engine
5. Update UI settings if needed

**Fixing a conversation issue:**
1. Check `ConversationEngine` message handling
2. Review `MCPFramework` tool execution
3. Check database queries in tests
4. Verify SQLite schema

**Improving the UI:**
1. Modify `Sources/UserInterface/`
2. Respect no-multi-pane architecture
3. Use proper logging (no print)
4. Test on macOS 14.0+

**Adding a tool operation:**
1. Define in `MCPFramework`
2. Implement in appropriate module
3. Add error handling and logging
4. Write tests in `Tests/MCPFrameworkTests/`
5. Document in README

---

## Remember: The Unbroken Method Is Operational

The Seven Pillars are not optional—they're the operating system of this project:

- **Continuous Context**: Never lose the thread. Use checkpoints.
- **Complete Ownership**: Fix what you find. No excuses.
- **Investigation First**: Read before changing. Verify before implementing.
- **Root Cause**: Fix fundamentals, not symptoms.
- **Complete Deliverables**: No "v1" placeholder code.
- **Structured Handoffs**: Document for the next developer.
- **Learning**: Record what you learn to prevent repeats.

**Every change is an opportunity to improve code quality, documentation, and team knowledge.**

---

## Quick Checklist: Before Starting Work

- [ ] Read this file (.clio/instructions.md)
- [ ] Read ai-assisted/THE_UNBROKEN_METHOD.md
- [ ] Check git status and recent commits
- [ ] Understand what user is asking for
- [ ] Use user_collaboration to checkpoint at session start
- [ ] Plan investigation before making changes
- [ ] Search codebase to understand patterns
- [ ] Checkpoint findings before implementation
- [ ] Build with make before committing
- [ ] Run tests if applicable
- [ ] Write clear commit messages
- [ ] Use user_collaboration at session end
