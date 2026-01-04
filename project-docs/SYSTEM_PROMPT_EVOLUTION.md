# System Prompt Evolution

**Purpose:** Track changes to SAM's system prompt over time, documenting rationale and impact.

---

## Version History

### Version 16 (January 4, 2026)

**Change:** Simplified verbose sections, removed dead code

**Rationale:**
Initial plan was to remove todo workflow instructions as redundant with AgentOrchestrator.
**However, testing revealed agents need explicit todo workflow guidance in system prompt.**
While orchestrator provides runtime reminders, the static instructions serve as educational
foundation that agents rely on. Reverted todo workflow section after user testing.

**Final Changes:**

**KEPT (After Reversion):**
1. **MULTI-STEP REQUESTS - TODO LIST WORKFLOW section** (buildSAMSpecificPatterns)
   - **Initially removed** as redundant with AgentOrchestrator
   - **REVERTED** after user testing showed agents need explicit guidance  
   - **Lesson:** Runtime reminders supplement but don't replace educational foundation
   - Static instructions serve as reference agents rely on for workflow understanding

**REMOVED (Dead Code):**
1. **buildWorkflowContinuationProtocol() function**
   - Entire function removed (~500 tokens)
   - **Why:** Never called, redundant with orchestrator's 4 continuation variants

2. **buildThinkToolGuidance() function**
   - Entire function removed (~80 tokens)
   - **Why:** Never called, guidance already in buildSAMSpecificPatterns

**Simplifications:**

1. **Tool Responsibility** (buildToolUsage)
   - **Before:** 6 lines with enforcement ("Continue working until...not give up...do not stop...")
   - **After:** 3 lines with principles ("Use tools repeatedly...try alternatives")
   - **Why:** AgentOrchestrator's graduated intervention system enforces continuation
   - **Token Savings:** ~40 tokens

2. **Think Tool** (buildSAMSpecificPatterns)
   - **Before:** 6 lines with "CRITICAL" warnings and enforcement
   - **After:** 1 line with principle ("Shows 'Thinking...' for complex planning...avoid consecutive calls")
   - **Why:** Principle is useful, but detailed enforcement is verbose
   - **Token Savings:** ~60 tokens

3. **Multi-Step Request Handling** (buildOperationalModes)
   - **Before:** 8 lines with "REQUIRED FIRST STEP" enforcement
   - **After:** 4 lines with principles (understand steps, process sequentially, complete all)
   - **Why:** Educational value remains, but enforcement language removed
   - **Token Savings:** ~40 tokens

**Total Token Savings:** ~720 tokens (~15% reduction from affected sections)
**Note:** Original estimate was ~1150 tokens, but todo workflow section was reverted (~430 tokens restored)

**What Remains (Preserved Components):**
- ✅ Core Identity (WHO SAM is)
- ✅ Current Date Context (hallucination prevention)
- ✅ Response Guidelines (quality standards)
- ✅ Tool Usage (general principles, tool schema guidance)
- ✅ Operational Modes (conversational vs task modes)
- ✅ Execution Standards (error recovery tactics, completion criteria)
- ✅ Communication Protocol (style guide)
- ✅ Context & Memory (memory operations, document import)
- ✅ Data Visualization Protocol (Mermaid vs Stable Diffusion decision rules)
- ✅ Workflow Mode (mode-specific guidance, only when enabled)
- ✅ Dynamic Iterations (iteration monitoring, only when enabled)
- ✅ Two-Phase Workflow (pattern recommendation)
- ✅ Sequential Lists (pattern guidance)
- ✅ **Todo Workflow Instructions (KEPT after reversion)**

**Behavioral Impact:**
- **Todo workflow preserved** - Agents need explicit static guidance despite runtime reminders
- **Dead code removed** - Cleaner codebase
- **Verbose sections simplified** - Clearer, more concise
- **No breaking changes** - All functionality intact

**Testing Results:**
- ✅ Build: PASS (`make build-debug`)
- ✅ No compile errors
- ✅ System prompt generates correctly
- ✅ User testing: Agents work correctly with todo workflow restored

**Files Modified:**
- `Sources/ConfigurationSystem/SystemPromptConfiguration.swift`
  - Removed 3 redundant sections
  - Simplified 3 verbose sections
  - Updated `currentVersion` from 15 → 16
  - Added version comment explaining changes

**Related Components (Orchestrator System):**
- `Sources/APIFramework/AgentOrchestrator.swift`
  - 4 context-aware continuation guidance variants (lines ~1576-1633)
  - Fresh todo state reads before workflow decisions
  - Graduated intervention system for enforcing continuation

- `Sources/MCPFramework/TodoReminderInjector.swift`
  - Todo-specific workflow reminders (lines ~40-120)
  - "DO THE ACTUAL WORK, THEN mark completed" enforcement
  - Runtime injection with every request when todos exist

**Migration Notes:**
- **Existing conversations:** Unchanged (keep old system prompt)
- **New conversations:** Automatically use Version 16
- **User action:** None required (automatic on next conversation)

---

### Version 15 (Prior to January 4, 2026)

**Description:** Previous version with comprehensive behavioral instructions in system prompt

**Components:**
- Complete todo workflow instructions in system prompt
- Workflow continuation protocol in system prompt  
- Detailed enforcement language throughout
- All behavioral rules statically defined

**Limitations:**
- Redundancy with orchestrator runtime guidance
- ~1150 extra tokens for duplicate instructions
- No runtime adaptability to workflow state
- Single enforcement location (system prompt)

---

## Design Principles

### Version 16+ Philosophy

**System Prompt Role:**
- Define WHO SAM is (identity, personality, user personalization)
- Define WHAT SAM can do (capabilities, features, tools available)
- Provide quality standards (formatting, citations, response guidelines)
- Teach patterns and modes (conversational vs task, two-phase workflow)

**Orchestrator Role:**
- Enforce HOW to behave during workflow (runtime behavioral guidance)
- Adapt to workflow state (todos, tools, iteration count)
- Provide context-aware continuations (4 variants)
- Handle workflow discipline (graduated interventions)

**Separation Benefits:**
1. **No Redundancy:** Each instruction appears once, in the right place
2. **Context-Aware:** Orchestrator adapts guidance to current state
3. **Maintainable:** Single source of truth for behavioral rules
4. **Efficient:** Shorter system prompt = more room for user context

### What Belongs in System Prompt vs Orchestrator

**System Prompt (Static, Identity/Capability):**
- ✅ "You are SAM, an AI assistant"
- ✅ "Available tools: file_operations, web_research, etc."
- ✅ "For research, provide direct sources"
- ✅ "Mermaid for charts, Stable Diffusion for images"
- ✅ "Conversational mode vs Task execution mode"

**Orchestrator (Dynamic, Behavioral Enforcement):**
- ✅ "Mark todo in-progress before doing work" (runtime reminder)
- ✅ "Do NOT provide multiple text responses without tools" (continuation guidance)
- ✅ "You have incomplete todos - follow workflow" (state-aware)
- ✅ Fresh todo state reads for accurate workflow decisions

**Grey Area (Case-by-Case Decision):**
- ⚠️ "Use tools repeatedly until complete" → Principle in prompt, enforcement by orchestrator
- ⚠️ "Understand all steps before starting" → Educational in prompt, workflow discipline by orchestrator
- ⚠️ "3-attempt error recovery rule" → Tactical guidance in prompt (not enforced)

---

## Future Opportunities

### Potential Further Simplifications

1. **Operational Modes Section** (buildOperationalModes)
   - Currently ~50 lines explaining conversational vs task modes
   - Could reduce to ~25 lines of high-level principles
   - **Risk:** Agents may need explicit mode teaching
   - **Testing Required:** Verify agents still understand mode differences

2. **Execution Standards Consolidation**
   - Error Recovery and Completion are separate sections
   - Could merge into single "Execution Standards" with subsections
   - **Benefit:** Cleaner structure, no content loss
   - **Risk:** Minimal (organizational change only)

3. **Dynamic Component Injection**
   - Currently all components loaded at conversation start
   - Could inject certain components only when relevant
   - **Example:** "Document Import Protocol" only when user attaches files
   - **Benefit:** Further token savings
   - **Risk:** Complex implementation, marginal benefit

### Monitoring & Iteration

**Success Metrics:**
- Agent adherence to todo workflow (no violations)
- No consecutive assistant messages (alternation maintained)
- Task completion rate (all steps finished)
- User satisfaction (no complaints about behavior changes)

**Red Flags (Revert if Observed):**
- Agents skipping todo workflow steps
- Increased consecutive text responses
- Tasks marked complete prematurely
- User confusion or complaints

**Next Review:** After 30 days of production usage (February 3, 2026)

---

## Lessons Learned

### From Version 15 → 16 Transition

1. **Dead Code Identification:**
   - `buildWorkflowContinuationProtocol()` was never called but remained in codebase
   - `buildThinkToolGuidance()` same issue
   - **Lesson:** Regular code audits prevent cruft accumulation

2. **Redundancy Discovery:**
   - Same todo workflow instructions appeared in 3 places (system prompt, orchestrator, TodoReminderInjector)
   - Identified through systematic comparison
   - **Lesson:** Regularly compare static prompts vs runtime injection systems

3. **Incremental Testing Works:**
   - Planned to test after each change
   - Build passed immediately after all changes
   - **Lesson:** Careful planning reduces iteration cycles

4. **Special Characters Matter:**
   - Curly quotes (' ') in source code broke simple find/replace
   - Required Python script with line-based replacement
   - **Lesson:** Check for special characters when automating edits

5. **Orchestrator-First Design:**
   - Runtime guidance is superior to static instructions for behavioral rules
   - Static prompts should focus on identity/capability
   - **Lesson:** Prefer runtime enforcement over static documentation for workflows

---

## Reference

### Related Documentation

- **Orchestrator Workflow:** `project-docs/AGENT_ORCHESTRATOR.md`
- **Todo System:** `project-docs/subsystems/todo-system.md`
- **System Prompt Config:** `Sources/ConfigurationSystem/SystemPromptConfiguration.swift`
- **Continuation Guidance:** `Sources/APIFramework/AgentOrchestrator.swift` (lines ~1550-1650)
- **Todo Reminders:** `Sources/MCPFramework/TodoReminderInjector.swift`

### Commit History

- **Version 16:** `[COMMIT_HASH]` - refactor(system-prompt): remove redundancy with orchestrator guidance (January 4, 2026)
- **Version 15:** (Previous default, no specific commit tracking)

---

**Document Version:** 1.0  
**Last Updated:** January 4, 2026  
**Maintainer:** SAM Development Team
