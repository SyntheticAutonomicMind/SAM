# System Prompt Evolution

**Purpose:** Track changes to SAM's system prompt over time, documenting rationale and impact.

---

## Version History

### Version 25 (July 29, 2026)

**Change:** Restore Assistant personality, add v25 anti-failure rules, fix cancellation and MLX build

**Rationale:**
After v24's "Agent Identity" reframing, SAM lost its helpful personality and became overly mechanical. Users reported cold, robotic responses. Also identified new failure patterns in agent behavior that needed explicit rules.

**Changes:**

**ADDED:**
1. **Assistant Personality Restoration** - Core Identity now includes "helpful, accurate, approachable, and genuinely interested in the user's goals" BEFORE the "YOU ARE AN AGENT" protocol
2. **Anti-Failure Rules (v25)** - New explicit rules addressing:
   - "Recent-session history is irrelevant" - Cannot use conversation history as excuse to skip tool calls
   - "Format inertia is not a tool call" - Reusing previous response format without new tool calls is fabrication
   - "Tool call must precede the matching text" - Specific claims require fresh tool verification
   - "Self-check before specific claims" - Mandatory verification step

**FIXED:**
- Cancellation handling in streaming responses
- MLX build issues with Swift 6 concurrency

**BEHAVIORAL IMPACT:**
- SAM now presents as a helpful agent, not a protocol executor
- Eliminates "fabrication by template reuse" failure mode
- Maintains agent completion discipline while restoring warmth

---

### Version 24 (July 29, 2026)

**Change:** Agent Identity + Completion Criteria

**Rationale:**
Fundamental identity-framing difference driving recurring bugs. The model self-identified as an assistant that helps by announcing, not an agent that works to completion. The "helpful assistant" framing caused narration-without-tool-call bugs (model would announce what it planned to do instead of doing it).

**Changes:**

**ADDED:**
1. **"YOU ARE AN AGENT" Core Identity** - Replaces "helpful assistant" framing with explicit agent protocol:
   - "Work autonomously until the user's request is resolved"
   - "PUSH TO ACTUAL LIMIT"
   - "YOU MUST NOT" list (narrate without acting, stop at 80%, leave errors unresolved, etc.)
2. **Completion Criteria Component** - Explicit completion standards:
   - "Narrating a tool action and ending without the tool call is abandonment, not completion"
   - "Personalities do not override completion"
   - Clear definition of what "done" means

**REMOVED:**
- "Helpful, accurate, and honest assistant" framing from Core Identity

**BEHAVIORAL IMPACT:**
- Eliminated narration-without-tool-call bugs
- Model now pushes to actual completion
- But: produced cold, mechanical tone (fixed in v25)

---

### Version 23 (July 29, 2026)

**Change:** Tool-Backed Claims Component

**Rationale:**
Addresses the failure mode of fabricating specifics (prices, ratings, URLs) by extending a prior tool-verified response template without re-running the tools. The model would produce fabricated results with the same framing as a previous verified response.

**Changes:**

**ADDED - "Tool-Backed Claims" Component (atomic):**
1. **Core Principle:** "A response that looks like a verified lookup must BE a verified lookup"
2. **Anti-Pattern Phrases (4):**
   - "Recent-session history is irrelevant"
   - "Format inertia is not a tool call"
   - "Tool call must precede the matching text"
   - "Self-check before specific claims"
3. **Cross-links:** From Workflow Loop "I'll search" rule, Tool Usage RESEARCH, Pre-Response Checklist #1, User Data Boundaries Section A

**BEHAVIORAL IMPACT:**
- Eliminates "duplicate-shape recall" / "format inertia" fabrication
- Each verifiable question gets its own tool call
- Domain-neutral - applies to all subjects

---

### Version 22 (July 29, 2026)

**Change:** Scope Honesty Component

**Rationale:**
Addresses the pattern of agents unilaterally narrowing user-stated scope - treating backup lists as filler, rationalizing shortcuts as efficiency, having opinions about scope without tool backing.

**Changes:**

**ADDED - "Scope Honesty" Component (atomic):**
1. **Core Principle:** "User sets the scope"
2. **Anti-Pattern Phrases (5):**
   - "Do not decide for the user that part of their scope is unnecessary"
   - "Backup, secondary, or lower-priority items get the same rigor"
   - "Scope-shrinking claims require tool backing"
   - "Do not rationalize shortcuts as efficiency or helpfulness"
   - "Self-check before scope-shrinking"
3. **Cross-links:** From User Autonomy, User Data Boundaries Section C

**BEHAVIORAL IMPACT:**
- All items in user's stated scope get equal rigor
- No unilateral scope-shrinking
- Backup/secondary items treated with same rigor as primary

---

### Version 21 (July 23, 2026)

**Change:** User Autonomy Component + Completion/Communication Rewrite

**Rationale:**
Addresses agent acting as user's time/energy/attention manager - unsolicited recaps, recap invitations, "are you tired", "take a break", "we can pick this up tomorrow", "is there anything else".

**Changes:**

**ADDED - "User Autonomy" Component (atomic):**
1. **Core Principle:** User authority over session boundaries, time, attention, response length
2. **Forbidden Behaviors:**
   - No unsolicited recaps
   - No session-boundary nudges ("we can pick this up tomorrow")
   - No attention management ("take a break", "you seem tired")
   - No manufactured decision points
3. **Domain-neutral:** "When the user is discussing any subject with an agent"

**REWRITTEN - Completion & Communication:**
- Removed "Conversational Partner Protocol" block
- Removed "What 'Done' Means" conversational bullet
- Removed Communication "When complete"/"Best practices"/"Never say" entries that mandated recaps
- Extended Pre-Response Checklist Mode Check with no-implicit-urgency rule

**BEHAVIORAL IMPACT:**
- Zero unsolicited session management
- User controls when conversation ends
- No manufactured urgency or decision points

---

### Version 20 (July 19, 2026)

**Change:** User Data Boundaries Component

**Rationale:**
Addresses silent assumption layering and user-list filtering - agents making assumptions about user data and filtering lists without tool backing.

**Changes:**

**ADDED - "User Data Boundaries" Component (atomic):**
- Section A: Numerical/Calculation Discipline (math_operations mandatory)
- Section B: Assumption Layering Prevention
- Section C: List Manipulation Discipline (no filtering user lists)
- Cross-linked from Tool Usage (math), Pre-Response Checklist

---

### Version 16 (January 4, 2026)

**Change:** Simplified verbose sections, removed dead code

**Rationale:**
Initial plan was to remove todo workflow instructions as redundant with AgentOrchestrator. However, testing revealed agents need explicit todo workflow guidance in system prompt. While orchestrator provides runtime reminders, the static instructions serve as educational foundation that agents rely on.

**Final Changes:**

**KEPT (After Reversion):**
1. **MULTI-STEP REQUESTS - TODO LIST WORKFLOW section** (buildSAMSpecificPatterns)
   - Initially removed as redundant with AgentOrchestrator
   - REVERTED after user testing showed agents need explicit guidance
   - Lesson: Runtime reminders supplement but don't replace educational foundation

**REMOVED (Dead Code):**
1. **buildWorkflowContinuationProtocol() function** (~500 tokens)
   - Entire function removed - never called, redundant with orchestrator's 4 continuation variants
2. **buildThinkToolGuidance() function** (~80 tokens)
   - Entire function removed - never called, guidance already in buildSAMSpecificPatterns

**Simplifications:**
1. **Tool Responsibility** (buildToolUsage) - 6 lines → 3 lines (~40 tokens saved)
2. **Think Tool** (buildSAMSpecificPatterns) - 6 lines → 1 line (~60 tokens saved)
3. **Multi-Step Request Handling** (buildOperationalModes) - 8 lines → 4 lines (~40 tokens saved)

**Total Token Savings:** ~720 tokens (~15% reduction from affected sections)

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

### Version 21+ Philosophy (User Autonomy + Scope Honesty + Tool-Backed Claims + Agent Identity)

**System Prompt Role (Expanded):**
- Define WHO SAM is (helpful, accurate, approachable agent)
- Define WHAT SAM can do (capabilities, features, tools available)
- Provide quality standards (formatting, citations, response guidelines)
- Teach patterns and modes (conversational vs task, two-phase workflow)
- **Assert user authority** over session, scope, and data boundaries
- **Define completion criteria** for agent work
- **Prevent fabrication** via tool-backed claims requirement

**Orchestrator Role (Enhanced):**
- Enforce HOW to behave during workflow
- Adapt to workflow state
- Provide context-aware continuations
- Handle workflow discipline
- **Guard against narration-without-tool-call** (orchestration-side)

---

## What Belongs in System Prompt vs Orchestrator

**System Prompt (Static, Identity/Capability/Boundaries):**
- [OK] "You are SAM, a helpful, accurate, approachable agent"
- [OK] "Available tools: file_operations, web_research, etc."
- [OK] "For research, provide direct sources"
- [OK] "Mermaid for diagrams and charts"
- [OK] "Conversational mode vs Task execution mode"
- [OK] "User controls session boundaries, time, attention"
- [OK] "All items in user's scope get equal rigor"
- [OK] "Every specific claim must be verified by a tool call"
- [OK] "Narrating a tool action and ending without the tool call is abandonment"

**Orchestrator (Dynamic, Behavioral Enforcement):**
- [OK] "Mark todo in-progress before doing work" (runtime reminder)
- [OK] "Do NOT provide multiple text responses without tools" (continuation guidance)
- [OK] "You have incomplete todos - follow workflow" (state-aware)
- [OK] Fresh todo state reads for accurate workflow decisions
- [OK] **Orchestration-side guard** for narration-without-tool-call detection

**Grey Area (Case-by-Case Decision):**
- [WARN] "Use tools repeatedly until complete" -> Principle in prompt, enforcement by orchestrator
- [WARN] "Understand all steps before starting" -> Educational in prompt, workflow discipline by orchestrator
- [WARN] "3-attempt error recovery rule" -> Tactical guidance in prompt (not enforced)

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
- No fabricated specifics (prices, ratings, URLs without tool calls)
- No unilateral scope-shrinking

**Red Flags (Revert if Observed):**
- Agents skipping todo workflow steps
- Increased consecutive text responses
- Tasks marked complete prematurely
- User confusion or complaints
- Cold, mechanical tone (personality lost)
- Fabricated specifics appearing in responses

**Next Review:** After 30 days of production usage

---

## Lessons Learned

### From Version 15 -> 16 Transition

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

### From Version 21-25 Transition

1. **Identity Framing is Load-Bearing:**
   - Removing "helpful" from Core Identity caused narration-without-tool-call bugs
   - Burying personality at end of prompt produced cold mechanical tone
   - **Fix:** Personality FIRST, agent protocol SECOND (both required)

2. **Atomic Components Win:**
   - Dedicated components (User Autonomy, Scope Honesty, Tool-Backed Claims) are discoverable and toggleable
   - Cross-linking makes relationships visible in editor
   - Surgical edits to existing components are error-prone

3. **Orchestration-Side Guards Needed:**
   - Prompt rules alone can't catch all failure modes
   - ResponseStatus differentiation makes abandonment observable in metrics
   - **Implementation:** Distinct status for "narration without tool call" vs "genuine completion"

---

## Reference

### Related Documentation

- **Orchestrator Workflow:** `project-docs/AGENT_ORCHESTRATOR.md`
- **Todo System:** `project-docs/subsystems/todo-system.md`
- **System Prompt Config:** `Sources/ConfigurationSystem/SystemPromptConfiguration.swift`
- **Continuation Guidance:** `Sources/APIFramework/AgentOrchestrator.swift` (lines ~1550-1650)
- **Todo Reminders:** `Sources/MCPFramework/TodoReminderInjector.swift`

### Commit History

- **Version 25:** `7a73a78` - fix(prompt): restore Assistant personality, add v25 anti-failure rules, fix cancellation and MLX build (July 29, 2026)
- **Version 24:** `cb4b501` - feat(prompt): agent identity + completion criteria (v24) (July 29, 2026)
- **Version 23:** `cadb858` - feat(prompt): add Tool-Backed Claims component (v23) (July 29, 2026)
- **Version 22:** `0f12aab` - feat(prompt): add Scope Honesty component (v22) (July 29, 2026)
- **Version 21:** `e2b8b79` - feat(prompt): add User Autonomy component to remove unsolicited recaps and session-boundary management (July 23, 2026)
- **Version 20:** `cbb6ccc` - feat(prompt): add User Data Boundaries component for numerical, assumption, and list discipline (July 19, 2026)
- **Version 16:** `[COMMIT_HASH]` - refactor(system-prompt): remove redundancy with orchestrator guidance (January 4, 2026)

---

**Document Version:** 2.0  
**Last Updated:** August 23, 2026  
**Maintainer:** SAM Development Team