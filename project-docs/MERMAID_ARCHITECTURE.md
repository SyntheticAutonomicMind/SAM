<!-- SPDX-License-Identifier: CC-BY-NC-4.0 -->
<!-- SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius) -->


# Mermaid Diagram Architecture

**Version:** 1.0  
**Last Updated:** November 28, 2025  
**Author:** GitHub Copilot (debugging session)

---

## Overview

SAM includes a **native Mermaid diagram renderer** that parses and displays Mermaid diagrams in real-time during streaming responses. This document explains the complete architecture, streaming challenges, and critical fixes required for proper diagram rendering.

---

## Supported Diagram Types

SAM supports **14 Mermaid diagram types:**

| Type | Example Syntax | Status |
|------|----------------|--------|
| Flowchart | `flowchart TD` | ✅ Fully supported |
| Sequence Diagram | `sequenceDiagram` | ✅ Fully supported |
| Class Diagram | `classDiagram` | ✅ Fully supported |
| State Diagram | `stateDiagram` | ✅ Fully supported |
| ER Diagram | `erDiagram` | ✅ Fully supported |
| Gantt Chart | `gantt` | ✅ Fully supported |
| Pie Chart | `pie` | ✅ Fully supported |
| User Journey | `journey` | ✅ Fully supported |
| Mindmap | `mindmap` | ✅ Fully supported |
| Timeline | `timeline` | ✅ Fully supported |
| Quadrant Chart | `quadrantChart` | ✅ Fully supported |
| Requirement Diagram | `requirementDiagram` | ✅ Fully supported |
| Git Graph | `gitGraph` | ✅ Fully supported |
| State Diagram v2 | `stateDiagram-v2` | ✅ Fully supported |

---

## Architecture Diagram

```mermaid
flowchart TD
  A[[LLM Streaming Response]]
  B[[(Assistant generates Mermaid code block during streaming)]]
  A --> B
```

---

## Streaming Challenges

### Challenge 1: Incomplete Code During Streaming

**Problem:**  
Code blocks arrive in chunks during streaming:
```
Chunk 1: "```mer"
Chunk 2: "maid"
Chunk 3: "flowchart TD"
Chunk 4: "A[Start] --> B[End]"
```

Parser is called on **every chunk** due to `.onChange(of: code)`.

**Result:**
- `"maid"` → Parser returns `.unsupported` 
- `"flowchart TD"` → Parser returns `.flowchart` with 0 nodes
- Final code → Parser returns complete diagram

### Challenge 2: When to Stop Re-Parsing?

**Problem:**  
If we re-parse on EVERY code change, we parse hundreds of times during streaming (expensive!).

If we STOP re-parsing too early, we miss the complete diagram.

**Balance needed:**
- Re-parse frequently enough to show progress
- Stop re-parsing when diagram is complete

### Challenge 3: Detecting "Complete" vs "Incomplete"

**Problem:**  
How do we know when a diagram is complete during streaming?

**Approaches tried:**

❌ **Stop after first successful parse:**
```swift
guard diagram == nil else { return }  // Only parse once
```
Result: Diagram stays `.unsupported` ("maid")

❌ **Stop after non-empty diagram:**
```swift
if !diagram.isEmpty { return }  // Stop when we have content
```
Result: Pie chart with 3 slices stops, misses remaining 7 slices

✅ **Continue while code length changes:**
```swift
if code.count != lastCodeLength {
    // Code still streaming, keep re-parsing
}
```
Result: Diagrams update until streaming completes!

---

## Complete Re-Parse Logic

### Decision Tree

```
Should we re-parse the diagram?

START
  │
  ▼
┌─────────────────────────┐
│ Do we have a diagram?   │ ──NO──> PARSE
└──────────┬──────────────┘
           │ YES
           ▼
┌─────────────────────────┐
│ Is it .unsupported?     │ ──YES──> PARSE (incomplete type)
└──────────┬──────────────┘
           │ NO (valid type)
           ▼
┌─────────────────────────┐
│ Is diagram empty?       │ ──YES──> PARSE (no content yet)
│ (below minimum thresh)  │
└──────────┬──────────────┘
           │ NO (has content)
           ▼
┌─────────────────────────┐
│ Is code still changing? │ ──YES──> PARSE (streaming in progress)
│ (length != last length) │
└──────────┬──────────────┘
           │ NO (stabilized)
           ▼
         STOP (diagram complete)
```

### Implementation

```swift
private func parseDiagram() {
    if let currentDiagram = diagram {
        switch currentDiagram {
        case .unsupported:
            // PARSE: Diagram type not recognized yet
            logger.debug("Re-parsing unsupported, length: \(code.count)")
            break
            
        default:
            // Check if diagram is empty
            let isEmpty = isDiagramEmpty(currentDiagram)
            
            // Check if code is still changing
            let codeStillChanging = code.count != lastCodeLength
            
            if isEmpty {
                // PARSE: Diagram has no content yet
                logger.debug("Re-parsing empty diagram, length: \(code.count)")
                break
            } else if codeStillChanging {
                // PARSE: Code still streaming
                logger.debug("Re-parsing (code changing: \(lastCodeLength) → \(code.count))")
                break
            }
            
            // STOP: Diagram complete, code stabilized
            logger.debug("Diagram complete, stabilized at \(code.count) chars")
            return
        }
    }
    
    // Update length tracker
    lastCodeLength = code.count
    
    // Parse diagram
    let parser = MermaidParser()
    let newDiagram = parser.parse(code)
    
    // Force SwiftUI to detect state change
    withAnimation {
        diagram = newDiagram
    }
}
```

### Minimum Viable Thresholds

To prevent stopping too early, we define minimum content requirements:

```swift
private func isDiagramEmpty(_ diagram: MermaidDiagram) -> Bool {
    switch diagram {
    case .flowchart(let fc):
        return fc.nodes.count < 2 || fc.edges.isEmpty
        
    case .sequence(let seq):
        return seq.participants.count < 2 || seq.messages.isEmpty
        
    case .pie(let pie):
        return pie.slices.count < 2  // Need at least 2 slices
        
    case .gantt(let gantt):
        return gantt.tasks.count < 2  // Need at least 2 tasks
        
    // ... etc for all diagram types
        
    case .unsupported:
        return false  // Handled separately
    }
}
```

**Why these thresholds?**
- Prevents accepting incomplete diagrams
- Most diagrams need multiple elements to be meaningful
- Balances between "wait for more" and "render now"

---

## Streaming Timeline Example

### Pie Chart Rendering During Streaming

```
Time | Code Received         | Parser Result           | Render?
-----|-----------------------|-------------------------|--------
t=0  | (empty)               | nil                     | ProgressView
t=1  | "```mer"              | .unsupported           | "unsupported type" code block
t=2  | "```mermaid"          | .unsupported           | (same)
t=3  | "pie"                 | .unsupported           | (same)
t=4  | "pie title Dist"      | .pie (0 slices)        | Empty pie (below threshold)
t=5  | "pie... \"A\" : 10"   | .pie (1 slice)         | Empty pie (below threshold)
t=6  | "pie... \"B\" : 20"   | .pie (2 slices)        | ✓ Render! (threshold met)
t=7  | "pie... \"C\" : 30"   | .pie (3 slices)        | ✓ Update! (code changing)
t=8  | "pie... \"D\" : 25"   | .pie (4 slices)        | ✓ Update! (code changing)
...  | ...                   | ...                     | ...
t=15 | "pie... \"J\" : 5"    | .pie (10 slices)       | ✓ Update! (code changing)
t=16 | (no more chunks)      | .pie (10 slices)       | ✓ Final! (code stabilized)
```

**Key Points:**
- Re-parses **15 times** during streaming
- Shows **progress** as diagram builds
- Stops when code **stabilizes** (no more changes)
- Final diagram is **complete**

---

## Critical Bugs Fixed

### Bug #1: All Diagrams Showing "Unsupported Type"

**Symptom:**  
Every Mermaid diagram showed "unsupported type" instead of rendering.

**Root Cause:**  
Parser was being called on incomplete code (e.g., "maid") and returning `.unsupported`. Once set to `.unsupported`, the guard prevented re-parsing:

```swift
// WRONG:
guard diagram == nil else { return }  // Never re-parse!
```

**Fix:**  
Allow re-parsing when diagram is `.unsupported`:

```swift
// CORRECT:
if let diagram = diagram {
    switch diagram {
    case .unsupported:
        break  // Allow re-parse
    default:
        return  // Don't re-parse valid diagrams
    }
}
```

### Bug #2: Diagrams Appearing as Empty Blocks

**Symptom:**  
Diagrams rendered as empty/blank blocks until conversation was switched.

**Root Cause:**  
SwiftUI wasn't detecting the state change when diagram changed from `.unsupported` to valid type.

**Fix:**  
Wrap diagram assignment in `withAnimation` to force SwiftUI update:

```swift
// Force SwiftUI to detect state change
withAnimation {
    diagram = newDiagram
}
```

### Bug #3: Empty Diagrams (Type Recognized, No Content)

**Symptom:**  
Parser recognized diagram type (e.g., "quadrantChart") but rendered empty (0 points).

**Root Cause:**  
Re-parsing stopped after valid type was detected, even though content hadn't arrived:

```swift
// WRONG:
if diagram != nil { return }  // Stop after first valid parse
```

**Fix:**  
Check if diagram is empty (below minimum threshold):

```swift
// CORRECT:
let isEmpty = isDiagramEmpty(diagram)
if isEmpty {
    break  // Keep re-parsing until we have content
}
```

### Bug #4: Partial Diagrams (Only First Few Items)

**Symptom:**  
Pie chart with 3 slices when there should be 10 total.

**Root Cause:**  
Re-parsing stopped once minimum threshold was met (2 slices), even though MORE content was still streaming:

```swift
// WRONG:
if !isDiagramEmpty(diagram) { return }  // Stop at threshold!
// Misses: slices 4, 5, 6, 7, 8, 9, 10
```

**Fix:**  
Track code length changes to detect ongoing streaming:

```swift
// CORRECT:
let codeStillChanging = code.count != lastCodeLength
if !isEmpty && !codeStillChanging {
    return  // Only stop when BOTH conditions met
}
```

---

## Performance Optimizations

### 1. Parse Throttling via Code Length Tracking

Instead of parsing on EVERY `.onChange` call (hundreds during streaming), we use **code length changes** as a proxy for "meaningful updates":

```swift
@State private var lastCodeLength: Int = 0

// Only update lastCodeLength when actually parsing
lastCodeLength = code.count
```

**Result:** Parse only when code GROWS, not on every character

### 2. Cached AST in MarkdownContentView

Markdown AST is cached and only re-parsed when content changes:

```swift
@State private var cachedAST: MarkdownASTNode?

.onChange(of: content) { _, _ in
    // Only re-parse if content actually changed
    if content != lastContent {
        parseAST()
    }
}
```

### 3. Lazy Parsing (Only When Visible)

Diagrams only parse `.onAppear`, not eagerly:

```swift
.onAppear {
    if preparsedDiagram == nil {
        parseDiagram()
    }
}
```

**Result:** Diagrams off-screen don't waste CPU

### 4. Pre-Parsed Diagrams for PDF/Print

For PDF export, diagrams are pre-parsed **synchronously** to avoid async rendering issues:

```swift
// Pre-parse BEFORE creating view
let parser = MermaidParser()
let parsedDiagram = parser.parse(code)

// Pass pre-parsed diagram
let diagramView = MermaidDiagramView(code: code, diagram: parsedDiagram)
```

---

## Testing Checklist

When modifying Mermaid rendering code, verify:

- [ ] All 14 diagram types render correctly
- [ ] Diagrams appear during streaming (not after completion)
- [ ] Partial diagrams update as more content streams
- [ ] Final diagrams are complete (all items present)
- [ ] Diagrams don't re-parse after streaming completes
- [ ] Switching conversations doesn't break rendering
- [ ] Scrolling doesn't trigger unnecessary re-parsing
- [ ] PDF export includes properly rendered diagrams
- [ ] Unsupported diagram types show code fallback

### Test Command

```bash
# Start SAM
make build-debug
pkill -9 SAM
nohup .build/Build/Products/Debug/SAM > sam_server.log 2>&1 & sleep 3

# Ask for Mermaid diagrams
# "Show me examples of flowchart, pie chart, and sequence diagram"

# Watch logs
tail -f sam_server.log | grep -E "Re-parsing|Parsed|Unsupported"

# Expected behavior:
# - Multiple "Re-parsing" logs during streaming
# - Final "Parsed X with N items" when complete
# - "Diagram complete, stabilized at X chars" when done
```

### Sample Test Prompts

```
"Create a flowchart showing the process of making coffee"

"Show me a pie chart of programming language popularity"

"Generate a sequence diagram for a user login flow"

"Create a Gantt chart for a 3-month project timeline"

"Show me a class diagram for a basic e-commerce system"
```

---

## Common Issues

### Issue 1: Diagram Shows "Unsupported Type"

**Diagnosis:**
```bash
grep "Unsupported diagram type" sam_server.log
```

**Possible Causes:**
- Diagram syntax error
- Unsupported diagram type
- Code not complete (still streaming)

**Fix:**
- Check diagram syntax matches Mermaid spec
- Verify diagram type is in supported list
- Wait for streaming to complete

### Issue 2: Diagram Renders Empty

**Diagnosis:**
```bash
grep "Parsed.*with 0" sam_server.log
```

**Possible Causes:**
- Parser recognized type but couldn't parse content
- Syntax error in diagram body
- Code incomplete (streaming cut off)

**Fix:**
- Verify diagram syntax
- Check parser implementation for that diagram type
- Re-generate diagram

### Issue 3: Diagram Renders Partially

**Diagnosis:**
```bash
grep -E "Re-parsing.*code length" sam_server.log | tail -20
```

**Possible Causes:**
- Code length stopped changing before streaming completed
- Minimum threshold set too high
- Parser bug

**Fix:**
- Check if final log shows "stabilized" message
- Verify isDiagramEmpty thresholds
- Inspect parser for that diagram type

### Issue 4: Diagram Constantly Re-Parsing

**Diagnosis:**
```bash
grep "Re-parsing" sam_server.log | wc -l  # Should be < 50 for most diagrams
```

**Possible Causes:**
- Code length keeps changing (infinite loop)
- isEmpty check always returns true
- View re-creating on scroll

**Fix:**
- Check if code.count actually stabilizes
- Verify isEmpty logic for diagram type
- Ensure view has stable ID

---

## Architecture Principles

### 1. Parse on Demand, Not Eagerly

Only parse when:
- View appears (`.onAppear`)
- Code changes (`.onChange`)
- Pre-parsing for PDF export

**Why:** Saves CPU for off-screen diagrams

### 2. Single Source of Truth

`@State private var diagram` is the ONLY source:

```swift
if let diagram = diagram {
    switch diagram {
        // Render based on THIS, not re-parsing
    }
}
```

**Why:** Consistent rendering, no race conditions

### 3. Fail Gracefully

If parsing fails, show code block:

```swift
case .unsupported:
    VStack {
        Text("MERMAID (unsupported type)")
        Text(code).font(.monospaced)
    }
```

**Why:** User can still see/copy diagram code

### 4. Progressive Enhancement

Diagrams update as content streams:

```
ProgressView → .unsupported code → Empty diagram → Partial diagram → Complete diagram
```

**Why:** Better UX than waiting for completion

---

## Related Documentation

- `docs/MESSAGING_ARCHITECTURE.md` - Message streaming architecture
- `docs/TOOL_CARD_ARCHITECTURE.md` - Tool card rendering
- `Sources/UserInterface/Chat/Mermaid/MermaidParser.swift` - Parser implementation
- `Sources/UserInterface/Chat/Mermaid/MermaidDiagramView.swift` - Main view
- `Sources/UserInterface/Chat/MarkdownViewRenderer.swift` - Markdown to SwiftUI

---

## Future Improvements

### 1. Debounced Re-Parsing

Instead of parsing on every code change, debounce:

```swift
@State private var parseTimer: Timer?

.onChange(of: code) { _, _ in
    parseTimer?.invalidate()
    parseTimer = Timer.scheduledTimer(withTimeInterval: 0.1) {
        parseDiagram()
    }
}
```

**Benefit:** Reduce parse count during rapid streaming

### 2. Incremental Parsing

Parse only NEW content, not entire diagram:

```swift
func parseIncremental(oldCode: String, newCode: String) {
    let delta = newCode.dropFirst(oldCode.count)
    // Parse only delta, append to existing diagram
}
```

**Benefit:** Much faster for large diagrams

### 3. Streaming-Aware Parser

Pass `isStreaming` flag to parser:

```swift
MermaidDiagramView(code: code, isStreaming: message.isStreaming)

if isStreaming {
    // More lenient parsing (allow incomplete)
} else {
    // Strict parsing (enforce complete)
}
```

**Benefit:** Better handling of incomplete diagrams

### 4. Caching Parsed Diagrams

Cache parsed diagrams by code hash:

```swift
static var diagramCache: [Int: MermaidDiagram] = [:]

let codeHash = code.hashValue
if let cached = Self.diagramCache[codeHash] {
    return cached
}
```

**Benefit:** Instant re-display on scroll

---

## Conclusion

Mermaid diagram rendering in SAM works by:

1. **Detecting** Mermaid code blocks in markdown
2. **Parsing** incrementally as code streams in
3. **Re-parsing** intelligently until code stabilizes
4. **Rendering** progressively as diagram builds
5. **Stopping** when diagram is complete

**Critical Insight:** The challenge is detecting "complete" during streaming. We solve this by tracking **code length changes** as a proxy for "streaming in progress".

**Key Principle:** Keep re-parsing while code is changing, stop when it stabilizes.

**Result:** Diagrams render completely and efficiently during streaming!
