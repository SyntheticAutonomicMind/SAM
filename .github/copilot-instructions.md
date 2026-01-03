<instructions>
# SAM Development Instructions

You are working on SAM - a native macOS AI assistant built with Swift/SwiftUI.

## MANDATORY FIRST STEPS - DO THIS BEFORE ANYTHING ELSE

**STOP! Before reading ANY code or user request:**

1. **Read THE UNBROKEN METHOD**: `cat ai-assisted/THE_UNBROKEN_METHOD.md`
   - This defines HOW you work, not just WHAT you build
   - Seven pillars govern ALL development work
   - Violations will cause session failure

2. **Check for continuation context**:
   - `ls -lt ai-assisted/ | head -20` - Find latest session handoff
   - Read CONTINUATION_PROMPT.md if exists
   - Review AGENT_PLAN.md for ongoing work

3. **Use collaboration tool IMMEDIATELY**:
   ```bash
   scripts/user_collaboration.sh "Session started.

   ✅ Read THE_UNBROKEN_METHOD.md: yes
   📋 Continuation context: [summary OR 'no active continuation']
   🎯 User request: [what user asked]

   Ready to begin? Press Enter:"
   ```

4. **Wait for user confirmation** - DO NOT proceed until user responds

5. **Review recent context**:
   - `git log --oneline -10`
   - Check for uncommitted changes: `git status`

**If you skip ANY of these steps, you are violating the Unbroken Method.**

---

## THE SEVEN PILLARS

These are the foundation of how you work. Violating any pillar is session failure.

### 1. Continuous Context
- Never break the conversation thread
- Use collaboration checkpoints throughout work
- Create structured handoffs when sessions must end
- Maintain context within and between sessions

### 2. Complete Ownership
- If you find a bug, YOU fix it
- Never say "out of scope" or "separate issue"
- Own all discovered problems during work
- Keep working until everything is resolved

### 3. Investigation First
- Read existing code before changing it
- Search for patterns: `git grep "pattern" Sources/`
- Understand WHY it works this way
- Share findings via collaboration tool BEFORE implementing

### 4. Root Cause Focus
- Fix problems, not symptoms
- Ask "why?" until you reach the fundamental issue
- Avoid quick hacks that mask underlying causes
- Solve architecturally, not just locally

### 5. Complete Deliverables
- No "TODO" comments or placeholders
- No "basic version first, expand later"
- Handle edge cases within scope
- Finish what you start, completely

### 6. Structured Handoffs
- Update ALL documentation before creating handoff
- Create comprehensive continuation prompts
- Include complete context for next session
- Document decisions, approaches, and lessons learned

### 7. Learning from Failure
- Document anti-patterns when discovered
- Add to project knowledge base
- Never repeat the same mistake
- Share lessons learned in handoffs

---

## COLLABORATION CHECKPOINT DISCIPLINE

**The collaboration tool is NOT optional. It's core to the methodology.**

Use `scripts/user_collaboration.sh` at these critical points:

### Session Start (MANDATORY)
```bash
scripts/user_collaboration.sh "Session started.

✅ Read THE_UNBROKEN_METHOD.md: yes
📋 Continuation context: [summary]
🎯 User request: [what they asked]

Ready to begin? Press Enter:"
```

### After Investigation (BEFORE Implementation)
```bash
scripts/user_collaboration.sh "Investigation complete.

🔍 What I found:
- [specific findings]

🎯 Proposed changes:
- [exact changes you will make]

📋 Testing plan:
- [how you will verify]

Approve this plan? Press Enter:"
```

### After Implementation (BEFORE Commit)
```bash
scripts/user_collaboration.sh "Implementation complete.

**Testing Results:**
- Build: [✅ PASS or ❌ FAIL with details]
- Manual: [what you tested + results]

**Status:** [Working/Broken/Needs Help]

Ready to commit? Press Enter:"
```

### Session End (ONLY When User Requests OR Work 100% Complete)
```bash
scripts/user_collaboration.sh "Work complete.

**Summary:**
- [what was accomplished]

**Status:**
- All tasks: [✅ Complete or 📋 Remaining work]
- Build: [✅ Passing or ❌ Failing]
- Tests: [✅ Passing or ❌ Failing]

Ready to end session? Press Enter:"
```

**CRITICAL RULES:**
- WAIT for user response at each checkpoint
- User may approve, request changes, or reject
- Default behavior: Keep working until user explicitly stops you
- Between checkpoints: Investigation and reading are OK without asking

---

## SAM-SPECIFIC DEVELOPMENT

### Build System

**Always use Makefile commands:**
```bash
make build-debug    # Debug builds
make clean          # Clean build artifacts
```

**NEVER use:**
- `swift build` - misses dependencies
- `swift run` - incomplete build
- `xcodebuild` directly - use Makefile

### Code Standards

#### Logging (MANDATORY)
```swift
import Logging
private let logger = Logger(label: "com.sam.component")

// Use logger, NEVER print()
logger.info("Action completed")  // No emojis in logs
logger.error("Error: \(error.localizedDescription)")
logger.debug("Detail: \(value)")
```

#### No Hardcoding
- Query metadata when available instead of hardcoding values
- Use dynamic lookups over static assumptions
- Validate inputs, don't assume

#### Commits
```bash
git add -A && git commit -m "type(scope): description

**Problem:**
[what was broken or missing]

**Solution:**
[how you fixed or built it]

**Testing:**
✅ Build: PASS
✅ Manual: [what you tested]
✅ Edge cases: [what you verified]"
```

**Commit types:** feat, fix, refactor, docs, test, chore

### Architecture Overview

**Key Components:**
- `Sources/API/` - REST API server (Vapor)
- `Sources/UserInterface/` - SwiftUI interface
- `Sources/Chat/` - Conversation engine
- `Sources/Models/` - Data models
- `Sources/Tools/` - Tool implementations (14 tools, 46+ operations)
- `Sources/MCP/` - Model Context Protocol integration

**Data Flow:**
```
User Input → ChatWidget → ConversationEngine → MessageBus → API Provider
                                                    ↓
                                                 Response
                                                    ↓
                                             ChatWidget Update
```

**Key Patterns:**
- Actor isolation for thread safety (Swift 6 strict concurrency)
- Logger for all output (no print statements)
- Environment-based dependency injection
- Centralized error handling

### File Locations

| Purpose | Path | Example |
|---------|------|---------|
| Source code | `Sources/` | `Sources/UserInterface/Chat/` |
| Conversations | `~/Library/Application Support/SAM/conversations/` | User data |
| Models (GGUF/MLX) | `~/Library/Caches/sam/models/` | Local models |
| SD Staging | `~/Library/Caches/sam/staging/stable-diffusion/` | Downloads |
| Generated Images | `~/Library/Caches/sam/images/` | Outputs |
| Temp Files | `scratch/` | `scratch/build.log` |
| Documentation | `project-docs/` | `project-docs/MCP_FRAMEWORK.md` |
| Handoffs | `ai-assisted/YYYY-MM-DD/HHMM/` | `ai-assisted/2025-12-19/1400/` |
| Website Docs | `../website/docs/` | External documentation |

**Important:** 
- Temp files → `scratch/` (gitignored)
- NEVER create temp files in repo root (will be committed)

---

## SESSION WORKFLOW

### Starting Work

1. ✅ Execute MANDATORY FIRST STEPS (above)
2. ✅ Check recent work: `git log --oneline -10`
3. ✅ Use collaboration tool for session start
4. ✅ Wait for user confirmation
5. ✅ Read relevant code before changing it

### During Work - Investigation → Checkpoint → Implementation

**For each task:**

1. **INVESTIGATE**
   - Read existing code: `cat Sources/Path/File.swift`
   - Search for patterns: `git grep "functionName" Sources/`
   - Understand WHY it works this way
   - Test current behavior if applicable

2. **CHECKPOINT** (collaboration tool)
   - Share findings
   - Propose approach
   - WAIT for approval

3. **IMPLEMENT**
   - Make exact changes from approved plan
   - Follow code standards
   - No surprises beyond approved plan

4. **TEST**
   - Build: `make build-debug`
   - Verify functionality works
   - Check for errors: `grep -i error sam_server.log`

5. **CHECKPOINT** (collaboration tool)
   - Show test results
   - Confirm status
   - WAIT for approval

6. **COMMIT**
   - Add changes: `git add -A`
   - Commit with full message (see Code Standards)
   - Include testing details in commit message

7. **CONTINUE**
   - Move to next task
   - Repeat cycle
   - Keep working until ALL issues resolved

### Ending Session (ONLY When Required)

**Session ends ONLY when:**
1. User explicitly requests handoff, OR
2. All work is 100% complete AND user validates, OR
3. High token usage AND work is at a good stopping point

**Before ending:**

1. **Fix ALL discovered issues** (Complete Ownership)

2. **Update ALL affected documentation:**
   - `ai-assisted/THE_UNBROKEN_METHOD.md` - If methodology changes
   - `project-docs/subsystems/*.md` - If subsystem behavior changed
   - `project-docs/flows/*.md` - If message/tool flow changed
   - `../website/docs/` - If user-facing features or APIs changed

3. **Commit all changes:**
   ```bash
   # If website was changed, commit submodule first
   cd ../website && git add -A && git commit -m "docs: update" && cd -
   
   # Then commit SAM changes
   git add -A && git commit -m "type(scope): description"
   ```

4. **Use collaboration tool for validation:**
   ```bash
   scripts/user_collaboration.sh "Work complete.
   
   **Summary:** [what was accomplished]
   **Documentation:** [what was updated]
   **Status:** [all tasks complete? build passing?]
   
   Ready to end session? Press Enter:"
   ```

5. **WAIT** - User may approve OR give more work

6. **If approved, create handoff** in `ai-assisted/YYYY-MM-DD/HHMM/`:
   - `CONTINUATION_PROMPT.md` - Complete standalone context
   - `AGENT_PLAN.md` - Remaining priorities
   - `CHANGELOG.md` - User-facing changes (if applicable)

---

## HANDOFF PROTOCOL

**When creating handoff documents:**

### Handoff Location
```
ai-assisted/YYYY-MM-DD/HHMM/
├── CONTINUATION_PROMPT.md  # Complete context for next session
├── AGENT_PLAN.md            # Remaining work breakdown  
└── CHANGELOG.md             # User-facing changes (optional)
```

**Examples:**
- `ai-assisted/2025-12-19/1400/` - Session at 2:00 PM
- `ai-assisted/2025-12-19/handoff/` - Named session

### CONTINUATION_PROMPT.md Structure

**Must include:**
- Session summary (what was accomplished)
- All commits made with descriptions
- Files modified and why
- Documentation updated (list what was updated)
- Testing performed and results
- Known issues remaining
- Build/project status
- Lessons learned
- Clear starting instructions for next session
- NO external references - document IS the context

**The Handoff Test:**
> Can someone start a new session with ONLY the CONTINUATION_PROMPT.md and immediately continue productive work?

If yes → handoff is complete  
If no → add more context

### AGENT_PLAN.md Structure

**Must include:**
- Remaining priorities (detailed breakdown)
- Investigation steps for each priority
- Success criteria for each task
- Dependencies between tasks
- Time estimates (if applicable)

---

## QUICK REFERENCE

### Most-Used Commands

```bash
# Collaboration (use at checkpoints)
scripts/user_collaboration.sh "message"

# Build
make build-debug

# Commit
git add -A && git commit -m "type(scope): description"

# Test SAM
pkill -9 SAM
nohup .build/Build/Products/Debug/SAM > sam_server.log 2>&1 & sleep 3
curl -X POST http://127.0.0.1:8080/api/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"test","messages":[{"role":"user","content":"test"}]}'
grep -i error sam_server.log

# Search codebase
git grep "pattern" Sources/

# Recent commits
git log --oneline -10

# Check for handoffs
ls -lt ai-assisted/ | head -20
```

---

## ANTI-PATTERNS (DO NOT DO THESE)

### Process Violations
❌ Skip session start collaboration checkpoint  
❌ Edit code without investigation + checkpoint  
❌ Commit without testing + checkpoint  
❌ End session without user approval  
❌ **Respond with text only - EVERY response MUST call at least one tool** (usually collaboration tool)
❌ **Respond without using collaboration tool during active session** (session failure)

### Methodology Violations
❌ Label bugs as "out of scope" (fix them - Complete Ownership)  
❌ Create partial implementations ("TODO for later")  
❌ Assume how code works (investigate first)  
❌ Stop at partial completion (55%, 80%, 90% - finish it)  
❌ Fix symptoms instead of root causes  

### Code Violations
❌ Use `print()` instead of logger  
❌ Use `swift build/run` instead of Makefile  
❌ Hardcode values when metadata is available  
❌ Add emojis to logs or code  
❌ Use `isBackground=true` in run_in_terminal (causes silent failures)

### Documentation Violations
❌ Skip updating documentation when behavior changes  
❌ Create handoffs in wrong location (must be in dated folder)  
❌ Create handoffs without complete context  
❌ Leave documentation out of sync with code

---

## REMEMBER

**You are working WITH a human partner. Collaboration is MANDATORY.**

The Seven Pillars are not suggestions. They are the methodology that enables success.

**Every checkpoint is a conversation.**  
**Every checkpoint requires you to WAIT.**  
**Every checkpoint can be rejected - and that's OK.**

The methodology works. Follow it exactly.

---

## COMPLETE WORKFLOW EXAMPLE

**User request:** "Fix the PDF table rendering bug"

```
1. SESSION START CHECKPOINT
   > scripts/user_collaboration.sh "Session started. User reports PDF table rendering bug. Ready to investigate."
   [WAIT for user]

2. INVESTIGATE
   > read_file: MessagePDFView.swift
   > git grep "NSTextTable" Sources/
   [Findings: NSTextTable doesn't render in PDF context]

3. INVESTIGATION CHECKPOINT
   > scripts/user_collaboration.sh "Investigation complete.
     Found: convertTable() uses NSTextTable which doesn't work in PDF.
     Proposed: Replace with Unicode grid rendering using monospaced font.
     Testing: Build + export PDF with table, verify grid appears.
     Approve?"
   [WAIT for user]

4. IMPLEMENT (after approval)
   > replace_string_in_file: MessagePDFView.swift
   [Make exact changes from approved plan]

5. TEST
   > make build-debug
   [Build successful]
   [Manually test: export PDF with table]

6. IMPLEMENTATION CHECKPOINT
   > scripts/user_collaboration.sh "Implementation complete.
     Testing: ✅ Build PASS, ✅ PDF exports with grid table.
     Status: Working.
     Ready to commit?"
   [WAIT for user]

7. COMMIT (after approval)
   > git add -A && git commit -m "fix(ui): render tables as Unicode grid in PDF"

8. CONTINUE TO NEXT TASK
   [Keep working - NO handoff unless user requests]
```

---

For detailed methodology principles, see: `ai-assisted/THE_UNBROKEN_METHOD.md`

</instructions>
