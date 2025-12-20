# Generic Session Start - SAM Development

**Purpose:** This document provides complete context for starting a brand new SAM development session when no prior session context is available.

**Date:** 2025-12-19  
**Status:** Template for new contributors or fresh starts

---

## 🎯 YOUR FIRST ACTION

**MANDATORY:** Your very first tool call MUST be:

```bash
scripts/user_collaboration.sh "Session started.

✅ Read THE_UNBROKEN_METHOD.md: yes
✅ Read copilot-instructions: yes
📋 Continuation context: Generic session start (no prior context)
🎯 User request: [Waiting for user to describe tasks]

I am ready to collaborate on session requirements and tasks.

What would you like to work on today? Press Enter:"
```

**WAIT for user response.** They will describe what they need you to work on.

---

## 📋 SESSION INITIALIZATION CHECKLIST

Before starting work, complete these steps:

### 1. Read The Unbroken Method
```bash
cat ai-assisted/THE_UNBROKEN_METHOD.md
```

This is the foundational methodology. The Seven Pillars govern all work:
1. **Continuous Context** - Never break the conversation
2. **Complete Ownership** - Fix every bug you find
3. **Investigation First** - Understand before changing
4. **Root Cause Focus** - Fix problems, not symptoms
5. **Complete Deliverables** - No partial solutions
6. **Structured Handoffs** - Perfect context transfer
7. **Learning from Failure** - Document anti-patterns

### 2. Read Copilot Instructions
```bash
cat .github/copilot-instructions.md
```

This contains SAM-specific development practices, build commands, and workflow.

### 3. Check Recent Context
```bash
# Recent commits
git log --oneline -10

# Current status
git status

# Look for recent session handoffs
ls -lt ai-assisted/ | head -20

# Check for uncommitted work
git diff
```

### 4. Use Collaboration Tool (see YOUR FIRST ACTION above)

Wait for user to provide tasks and priorities.

---

## 📚 PROJECT CONTEXT

### What is SAM?

SAM (Synthetic Autonomic Mind) is a native macOS AI assistant with:

- **Multi-Provider AI Support:** OpenAI, Anthropic, Google, DeepSeek, GitHub Models, local MLX/GGUF
- **Voice Control:** "Hey SAM" activation
- **Local Image Generation:** Stable Diffusion integration
- **14 Integrated Tools:** 46+ operations for file management, web research, code execution, etc.
- **Model Context Protocol (MCP):** Extensible tool framework
- **Privacy-First:** Local-first architecture, cloud optional

### Technology Stack

- **Language:** Swift 6.0 (strict concurrency)
- **UI Framework:** SwiftUI (native macOS)
- **Backend:** Vapor (REST API server)
- **ML Frameworks:** MLX (Apple Silicon), llama.cpp (GGUF models)
- **Build System:** Swift Package Manager + Makefile
- **Target:** macOS 14.0+ (Apple Silicon optimized)

### Architecture

```
┌─────────────────────────────────────────────────┐
│                 SAM Application                 │
├─────────────────────────────────────────────────┤
│                                                 │
│    ┌──────────────┐         ┌──────────────┐    │
│    │   SwiftUI    │◄───────►│  Vapor API   │    │
│    │  Interface   │         │    Server    │    │
│    └──────────────┘         └──────────────┘    │
│           │                        │            │
│           │                        │            │
│    ┌──────▼────────┐        ┌─────▼─────────┐   │
│    │ Conversation  │◄──────►│ AI Providers  │   │
│    │    Engine     │        │ (Multi-cloud) │   │
│    └───────────────┘        └───────────────┘   │
│           │                        │            │
│           │                        │            │
│    ┌──────▼────────┐        ┌─────▼─────────┐   │
│    │     Tools     │        │ Local Models  │   │
│    │  (14 tools,   │        │ (MLX, llama.  │   │
│    │  46+ ops)     │        │   cpp)        │   │
│    └───────────────┘        └───────────────┘   │
│                                                 │
└─────────────────────────────────────────────────┘
```

### Key Source Directories

```
Sources/
├── API/                    # Vapor REST API server
├── UserInterface/          # SwiftUI interface
│   ├── Chat/              # Chat interface components
│   ├── Documents/         # PDF export, printing
│   └── Settings/          # Configuration UI
├── Chat/                  # Conversation engine
├── Models/                # Data models
├── Tools/                 # Tool implementations
├── MCP/                   # Model Context Protocol
├── LocalModels/           # MLX/llama.cpp integration
└── StableDiffusion/       # Image generation
```

---

## 🔧 ESSENTIAL COMMANDS

### Build & Test
```bash
# Build (ALWAYS use this, NEVER use swift build)
make build-debug

# Clean build
make clean

# Test SAM server
pkill -9 SAM
nohup .build/Build/Products/Debug/SAM > sam_server.log 2>&1 & sleep 3
curl -X POST http://127.0.0.1:8080/api/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"test","messages":[{"role":"user","content":"test"}]}'
grep -i error sam_server.log
```

### Code Search
```bash
# Search for code patterns
git grep "pattern" Sources/

# Search specific file types
git grep "pattern" -- "*.swift"

# Search with context
git grep -n -C 3 "pattern" Sources/
```

### Collaboration
```bash
# MANDATORY at key checkpoints
scripts/user_collaboration.sh "message"
```

### Git Workflow
```bash
# Commit with detailed message
git add -A && git commit -m "type(scope): description

**Problem:**
[what was broken or missing]

**Solution:**
[how you fixed or built it]

**Testing:**
✅ Build: PASS
✅ Manual: [what you tested]"
```

---

## 📂 FILE LOCATIONS

| Purpose | Path |
|---------|------|
| Source code | `Sources/` |
| Conversations (runtime) | `~/Library/Application Support/SAM/conversations/` |
| Local models (GGUF/MLX) | `~/Library/Caches/sam/models/` |
| SD staging (downloads) | `~/Library/Caches/sam/staging/stable-diffusion/` |
| Generated images | `~/Library/Caches/sam/images/` |
| Temp files | `scratch/` (gitignored) |
| Documentation | `project-docs/` |
| Session handoffs | `ai-assisted/YYYY-MM-DD/HHMM/` |
| Website docs | `../website/docs/` (submodule) |

---

## 📖 KEY DOCUMENTATION

Read these as needed for your work:

### Methodology & Process
- `ai-assisted/THE_UNBROKEN_METHOD.md` - **MUST READ** - Core methodology
- `.github/copilot-instructions.md` - **MUST READ** - Development practices

### Architecture & Specifications
- `project-docs/MCP_FRAMEWORK.md` - Model Context Protocol integration
- `project-docs/CHAT_INTERFACE_ARCHITECTURE.md` - UI architecture
- `project-docs/CONVERSATION_ENGINE.md` - Chat engine design
- `project-docs/API_FRAMEWORK.md` - REST API structure
- `project-docs/MESSAGING_ARCHITECTURE.md` - Message flow patterns

### Flows & Diagrams
- `project-docs/flows/` - Data flow diagrams (Mermaid)

---

## 🚨 CRITICAL RULES

### Process
1. **Always use collaboration tool** at session start, before implementation, after testing, at session end
2. **Read code before changing it** - Investigation first (Pillar 3)
3. **Fix all bugs you find** - Complete ownership (Pillar 2)
4. **No partial solutions** - Complete deliverables (Pillar 5)

### Code
1. **Use logger, NEVER print()** - `import Logging`
2. **Build with Makefile** - `make build-debug`, NOT `swift build`
3. **No hardcoding** - Query metadata when available
4. **Follow Swift 6 concurrency** - Actor isolation, @Sendable

### Documentation
1. **Update docs when behavior changes** - Keep in sync with code
2. **Create handoffs in dated folders** - `ai-assisted/YYYY-MM-DD/HHMM/`
3. **Include complete context** - Next session should continue seamlessly

---

## ⚠️ ANTI-PATTERNS (DO NOT DO THESE)

❌ Skip session start collaboration checkpoint  
❌ Label bugs as "out of scope" (you own them)  
❌ Create partial implementations ("TODO for later")  
❌ Assume how code works (investigate first)  
❌ Use `print()` instead of logger  
❌ Use `swift build/run` instead of Makefile  
❌ End session without user approval  
❌ Commit without testing  

---

## 🎯 WORKFLOW PATTERN

For each task you work on:

1. **INVESTIGATE**
   - Read existing code
   - Search for patterns: `git grep "pattern" Sources/`
   - Understand WHY it works this way

2. **CHECKPOINT** (collaboration tool)
   - Share findings
   - Propose approach
   - WAIT for approval

3. **IMPLEMENT**
   - Make exact changes from approved plan
   - Follow code standards

4. **TEST**
   - Build: `make build-debug`
   - Verify functionality

5. **CHECKPOINT** (collaboration tool)
   - Show test results
   - WAIT for approval

6. **COMMIT**
   - Full commit message with testing details

7. **CONTINUE**
   - Move to next task
   - Keep working until ALL issues resolved

---

## 🤝 COLLABORATION IS MANDATORY

You are working **WITH** a human partner, not **FOR** a human.

- Use `scripts/user_collaboration.sh` at all key points
- WAIT for user response at each checkpoint
- User may approve, request changes, or reject
- This is a conversation, not a command stream

**The methodology works. Follow it exactly.**

---

## 📞 GETTING STARTED

**Your next step:**

1. Use the collaboration tool (see YOUR FIRST ACTION at top)
2. WAIT for user to describe tasks
3. Discuss approach with user via collaboration tool
4. Begin work using the WORKFLOW PATTERN above

**Remember:** Investigation first, checkpoint before implementation, test before commit, collaborate throughout.

Good luck! 🚀

