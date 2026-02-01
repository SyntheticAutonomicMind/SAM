# SAM - CLIO Project Instructions

**Project:** Synthetic Autonomic Mind (SAM)  
**Language:** Swift 6.0+  
**Platform:** macOS 14.0+ (native)  
**Build System:** Swift Package Manager + Makefile  
**License:** GPL-3.0-only

---

## Quick Reference

- **Repository:** https://github.com/SyntheticAutonomicMind/SAM
- **Build:** `make build-debug` / `make build-release`
- **Test:** `swift test` / `./Tests/run_all_tests.sh`
- **Run:** `.build/Build/Products/Debug/SAM.app/Contents/MacOS/SAM`
- **Architecture:** Modular, actor-based, Swift 6 concurrency throughout

---

## Core Methodology: The Unbroken Method

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

## Collaboration Checkpoint Discipline (MANDATORY)

**Use collaboration tool at EVERY key decision point:**

| Checkpoint | When | Purpose |
|-----------|------|---------|
| Session Start | Multi-step work OR handoff recovery | Evaluate request, develop plan, confirm with user |
| After Investigation | Before implementation | Share findings, get approval |
| After Implementation | Before commit | Show results, get OK |
| Session End | When work complete | Summary & handoff |

### Session Start Checkpoint Format

**CORRECT:**
```
Based on your request to [X], here's my plan:
1) [investigation step with files to read]
2) [implementation step with changes to make]
3) [verification step with tests to run]

Proceed with this approach?
```

**WRONG:**
- "What would you like me to do?" (user already told you)
- "Please confirm the context..." (you should investigate first)
- Starting implementation without checkpoint

The user has already provided their request. Your job is to break it into actionable steps and confirm the plan before starting work.

### Guidelines

- [OK] Investigate freely (reading files, searching code, git status)
- [CHECKPOINT REQUIRED] Checkpoint BEFORE making changes
- [OK] Checkpoint AFTER implementation (show results)
- [SKIP] Single-line explanations, pure research, answering questions

---

## Swift 6 Concurrency (CRITICAL - Non-Negotiable)

All code in SAM MUST follow Swift 6 strict concurrency rules. This is not optional.

### Rules (Do NOT Skip These)

1. **Sendable Conformance Required**
   - All types crossing actor boundaries must conform to `Sendable`
   - Use `@unchecked Sendable` ONLY when safe, with documentation
   - Document WHY it's safe

2. **MainActor Isolation for UI**
   - All SwiftUI views and ViewModels MUST be `@MainActor`
   - NSAttributedString operations MUST run on MainActor
   - AppKit/UIKit operations require MainActor

3. **Capture Before Crossing Actor Boundaries**
   ```swift
   // [FAIL] BAD - will not compile
   await withTaskGroup { group in
       group.addTask { await self.property.doSomething() }
   }
   
   // [OK] GOOD - captures first
   let property = self.property
   await withTaskGroup { group in
       group.addTask { await property.doSomething() }
   }
   ```

4. **Expected Build Results**
   - **0 errors** (always - non-negotiable)
   - **~211 warnings** (Sendable-related, non-blocking, acceptable)
   - Run `make build-debug` to verify locally
   - Run `./scripts/test_like_pipeline.sh` to simulate CI/CD

### Common Patterns in SAM

See `project-docs/SWIFT6_CONCURRENCY_MIGRATION.md` for:
- Wrapper types for non-Sendable dictionaries (e.g., `SendableParams`)
- Using `nonisolated(unsafe)` for safe immutable state
- Capture patterns in loops and closures
- Custom type erasure for Sendable compliance

### When You Encounter Concurrency Issues

1. **First attempt:** Add proper actor boundaries and Sendable conformance
2. **Second attempt:** Use capture-before-crossing pattern
3. **Third attempt:** Read the concurrency migration guide, consult similar code
4. **Report:** Explain what you tried and ask user for guidance

---

## Code Style & Conventions (Enforce These)

### SPDX License Headers (MANDATORY)

Every Swift file MUST start with:
```swift
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)
```

This is non-negotiable. Reject any commit without it.

### Naming Conventions

- **Classes/Structs/Enums:** `PascalCase` (e.g., `ConversationManager`, `ModelLoadingActor`)
- **Functions/Variables:** `camelCase` (e.g., `loadModel()`, `conversationHistory`)
- **Constants:** `camelCase`, NOT `SCREAMING_SNAKE_CASE` (e.g., `let maxTokens = 2048`)
- **Protocols:** Descriptive names ending in `Protocol` when needed (e.g., `ToolRegistryProtocol`)
- **Actors:** `PascalCase` with `Actor` suffix when ambiguous (e.g., `ModelLoadingActor`)

### Comments & Documentation

- **Documentation comments:** `///` (shown in Xcode Quick Help)
- **Implementation comments:** `//` (explain WHY, not WHAT)
- **Section markers:** `// MARK: -` to organize code sections
- **Document intent:** Code should be self-documenting; comments explain decisions

### Logging (NEVER use print())

Use `swift-log` Logger only:
```swift
private let logger = Logger(label: "com.sam.modulename")

logger.debug("Debug message")
logger.info("Info message")
logger.warning("Warning message")
logger.error("Error message")
```

Logger label format: `com.sam.<module>` (e.g., `com.sam.orchestrator`, `com.sam.conversation`)

---

## Build & Test Workflow

### Build Commands

```bash
make build-debug        # Debug build (faster, includes symbols)
make build-release      # Release build (optimized)
make build-dev          # Dev release (auto-increments -dev.N)
make clean              # Clean all artifacts
make llamacpp           # Build llama.cpp framework only
```

### Test Commands

```bash
swift test                      # All unit tests
swift test --filter MyTests     # Specific test suite
./Tests/run_all_tests.sh        # Unit + e2e tests
./Tests/mcp_api_tests.sh        # MCP API tests
./scripts/test_like_pipeline.sh # Like CI/CD
```

### Verification Before Commit

```bash
# Always do this before committing:
make clean
make build-debug
./scripts/test_like_pipeline.sh
git status  # Ensure no unintended changes
```

---

## Git & Commit Discipline

### Commit Message Format (Conventional Commits)

```
<type>(<scope>): <subject>

[optional body]

[optional footer]
```

**Types:** `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `perf`, `style`, `ci`

**Scopes:** `ui`, `api`, `mcp`, `conversation`, `config`, `build`, `voice`, `training`, `image`, `memory`

**Examples:**
```bash
git commit -m "feat(mcp): Add web scraping tool with structured data extraction"
git commit -m "fix(ui): Prevent toolbar overflow on narrow windows"
git commit -m "refactor(api): Extract streaming logic into separate service"
```

### Before Every Commit

```bash
# 1. Verify no handoff files are staged
git status | grep "ai-assisted" && echo "ERROR: Remove handoff files" || echo "OK"

# 2. Review changes
git diff --staged

# 3. Run tests
./scripts/test_like_pipeline.sh

# 4. If everything passes, commit
git commit -m "type(scope): description"
```

---

## Investigation-First Principle

**Before making ANY changes, understand the context:**

1. **Read the relevant code**
   - Find the file/function you're modifying
   - Read surrounding code for context
   - Check existing patterns and conventions

2. **Check current state**
   - `git status` - what's changed?
   - `git log` - recent commits
   - Check if similar features exist

3. **Search for patterns**
   - Use semantic_search for unknown code locations
   - grep_search for specific patterns
   - Look at tests to understand expected behavior

4. **Use multiple tools in parallel**
   - If you need to investigate multiple areas, do it in one function call
   - Don't wait for one result before searching the next

---

## Multi-Step Task Workflow (MANDATORY)

Use todo_operations for ANY work spanning multiple steps:

```
1. CREATE todo list (with all tasks as "not-started")
2. Mark first as "in-progress"
3. DO THE WORK
4. Mark complete (immediately after finishing)
5. Mark next as "in-progress"
6. Repeat until all done
```

**ANTI-PATTERN (WRONG):**
```
"I'll create a todo list:
1. Read code
2. Fix bugs
3. Test

Let's get started..."
[Never creates todo in system]
```

**CORRECT (RIGHT):**
```
[Calls todo_operations with 3 todos]
[Marks #1 in-progress]
[Does the work]
[Calls todo_operations to mark #1 done]
[Calls todo_operations to mark #2 in-progress]
[Continues...]
```

---

## Common Development Tasks

### Adding a New Tool to MCP Framework

1. **Create:** `Sources/MCPFramework/Tools/MyTool.swift`
2. **Implement:** `MCPTool` protocol with all required methods
3. **Register:** In `UniversalToolRegistry`
4. **Test:** Add tests in `Tests/MCPFrameworkTests/`
5. **Document:** Tool's docstring, operation descriptions
6. **Commit:** `feat(mcp): Add my-tool with X operations`

### Adding a New AI Provider

1. **Create:** `Sources/APIFramework/Providers/MyProvider.swift`
2. **Implement:** `APIProvider` protocol
3. **Handle:** Streaming responses, error handling
4. **Test:** Mock responses, edge cases
5. **Register:** In `ProviderRegistry`
6. **Commit:** `feat(api): Add MyProvider support`

### Fixing a Bug

1. **Investigate:** Read code, reproduce bug, understand root cause
2. **Fix:** Make minimal change, don't refactor unrelated code
3. **Test:** Add test that catches this bug
4. **Commit:** `fix(scope): Description of fix, not symptoms`

### Updating Dependencies

```bash
swift package update              # Update SPM packages
swift package describe            # Check current versions
git add Package.resolved           # Commit new resolution
```

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

**NEVER:**
- Give up after first failure
- Stop when errors remain unresolved
- Skip items in a batch because one failed
- Say "I cannot do this" without trying alternatives

---

## Session Handoff Procedures (MANDATORY)

When ending a session, ALWAYS create a properly structured handoff:

```
ai-assisted/YYYYMMDD/HHMM/
├── CONTINUATION_PROMPT.md  [MANDATORY]
├── AGENT_PLAN.md           [MANDATORY]
├── CHANGELOG.md            [OPTIONAL]
└── NOTES.md                [OPTIONAL]
```

### NEVER COMMIT Handoff Files

**[CRITICAL] BEFORE EVERY COMMIT:**

```bash
git status | grep "ai-assisted" && echo "ERROR: Remove handoff" || echo "OK"
git reset HEAD ai-assisted/
git commit -m "type(scope): description"
```

Handoff files are INTERNAL SESSION CONTEXT. They must NEVER appear in public repository commits.

### CONTINUATION_PROMPT.md (MANDATORY)

**Provides complete context for next session.** Minimum content:

- What Was Accomplished (✓ completed tasks)
- Current State (code changes, test results, git commits)
- What's Next (Priority 1/2/3 tasks with specific file paths)
- Key Discoveries & Lessons Learned
- Context for Next Developer (architecture notes, known issues)

### AGENT_PLAN.md (MANDATORY)

**Remaining work plan.** Minimum content:

- Current Blockers (specific issues preventing progress)
- Immediate Next Steps (actionable first tasks)
- Medium-term Goals (upcoming features)
- Open Questions (decisions needed from user)

---

## Project-Specific Notes

### Privacy First

- NO telemetry, NO tracking by default
- All data stays on Mac unless user chooses cloud
- API credentials stored locally (UserDefaults, consider KeychainManager)
- Local models run entirely offline (MLX, llama.cpp)

### Performance Considerations

- Apple Silicon optimization is priority (arm64 Metal, MLX acceleration)
- Intel support is secondary
- MLX Metal library bundle must be embedded
- Large models require significant RAM (16GB+ recommended)

### Critical Files (Never Break These)

- `Info.plist` - Version, bundle ID, entitlements
- `Package.swift` - Dependencies, targets
- `Makefile` - Build system
- `SAM.entitlements` - Sandbox permissions
- `external/llama.cpp/` - Submodule (don't modify directly)

---

## Troubleshooting

### Build Fails: "llama.cpp not found"

```bash
git submodule update --init --recursive
make clean llamacpp
make build-debug
```

### Swift 6 Concurrency Errors

1. Check for actor boundaries
2. Verify Sendable conformance
3. Use capture-before-crossing pattern
4. See `project-docs/SWIFT6_CONCURRENCY_MIGRATION.md`

### Tests Fail

```bash
cd SAM  # Always from root
swift test
./Tests/run_all_tests.sh
```

### DMG Creation Fails

```bash
make build-release
make create-dmg  # Or part of `make distribute`
```

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

*Last Updated: 2026-02-01*
