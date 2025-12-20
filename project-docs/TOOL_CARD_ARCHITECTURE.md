<!-- SPDX-License-Identifier: CC-BY-NC-4.0 -->
<!-- SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius) -->


# Tool Card Architecture

**Version:** 1.0  
**Last Updated:** November 28, 2025  
**Author:** GitHub Copilot (debugging session)

---

## Overview

Tool execution cards display real-time tool execution status in SAM's chat interface. This document explains the complete architecture, data flow, and critical rendering requirements discovered through extensive debugging.

---

## Critical Requirements

### 1. Instant Visibility (<100ms)

Tool cards MUST appear instantly when tools are executed, NOT when they complete.

**Why:** Users need immediate feedback that the system is working. Delays create perception of lag or freezing.

### 2. Stable Titles

Tool card titles must remain consistent throughout execution lifecycle.

**Why:** Changing titles (e.g., "Image Generation" → "SUCCESS: Generated...") confuse users and look unprofessional.

### 3. Complete Output Display

SUCCESS messages and tool results must appear as OUTPUT inside the tool card, not as titles.

**Why:** Users need to see actual tool results, not generic "operation completed" messages.

---

## Architecture Diagram

````mermaid
flowchart LR
    AO[AgentOrchestrator]
    MB[ConversationMessageBus<br/>addToolMessage()]
    CW[ChatWidget<br/>ForEach(messages)]
    TMWC[ToolMessageWithChildren]
    TEC[ToolExecutionCard]

    AO -->|create tool message| MB
    MB -->|@Published messages| CW
    CW -->|render tool message| TMWC
    TMWC --> TEC

    subgraph UI-Handshakes
        AO -.->|toolCardsPending set| Pending[(toolCardsPending : Set<id>)]
        CW -.->|ack on appear| Ready[(toolCardsReady : Set<id>)]
        Ready -.-> AO
    end
````

---

## Message Lifecycle

### Phase 1: Tool Message Creation (t=0ms)

```swift
// AgentOrchestrator.swift
let toolMessageId = conversation.messageBus?.addToolMessage(
    id: UUID(),
    name: execution.toolName,
    status: .running,  // Initially running
    details: [],       // Empty initially
    toolDisplayData: nil,
    toolCallId: execution.toolCallId
)
```

**Message State:**
- `content`: "" (empty)
- `type`: .toolExecution
- `toolStatus`: .running
- `toolName`: "image_generation"

**CRITICAL:** Message is created with EMPTY content!

### Phase 2: MessageBus Processing (t=0ms, synchronous)

```swift
// ConversationMessageBus.swift - appendMessage()
messages.append(message)
messageCache[message.id] = messages.count - 1

if message.isToolMessage {
    messages = messages  // Force @Published to trigger
    conversation?.syncMessagesFromMessageBus()  // Synchronous sync
}
```

**What Happens:**
1. Message added to array
2. Array reassignment forces `@Published` to fire `objectWillChange`
3. Sync to ConversationModel (for persistence)

**CRITICAL:** Must be synchronous, NOT `Task { @MainActor }`!

### Phase 3: SwiftUI Re-Render (t<100ms)

```swift
// ChatWidget.swift - messagesVStack()
ForEach(messages) { message in
    // Filter check
    let isEmpty = message.content.isEmpty && 
                  message.type != .toolExecution  // ← CRITICAL EXCEPTION
    
    if !isEmpty {  // Tool messages ALWAYS pass
        if message.isToolMessage {
            ToolMessageWithChildren(...)
        }
    }
}
```

**CRITICAL:** Tool execution messages must NEVER be filtered, even when empty!

**Why:** Tool cards are created with empty content. If filtered by `isEmpty`, they won't render until Phase 5 when content is filled in.

### Phase 4: Card Renders with "Running..." State (t<100ms)

```swift
// ToolExecutionCard.swift
VStack {
    HStack {
        Image(systemName: icon)
        Text(getOperationDisplayName())  // "Image Generation"
        statusBadge  // Shows running state
    }
    
    if !isExpanded {
        Text("Running...")  // Collapsed state
    }
}
.onAppear {
    logger.error("TOOL_CARD_RENDERED: tool=\(toolName) ...")
}
```

**User sees:** Card header with "Running..." message

### Phase 5: Tool Completion (t=variable, seconds later)

```swift
// AgentOrchestrator.swift - After tool completes
conversation.messageBus?.updateMessage(
    id: toolMessageId,
    content: "SUCCESS: Generated and displayed 1 image to the user",
    status: .success,
    duration: 3.5
)
```

**Message State Updated:**
- `content`: "SUCCESS: ..." (filled in)
- `toolStatus`: .success
- `toolDuration`: 3.5

### Phase 6: Card Updates to Show Results (t<100ms)

```swift
// ToolExecutionCard.swift - Expanded view
if !message.content.isEmpty && !isProgressIndicator {
    VStack {
        Text("Output:")
        MarkdownText(message.content)  // Shows "SUCCESS: ..."
    }
}
```

**User sees:** Output section with actual tool results

---

## Critical Bugs Fixed

### Bug #1: Tool Cards Delayed 2-6 Seconds

**Symptom:** Tool cards wouldn't appear until tool completed and response started streaming.

**Root Cause:** ChatWidget was filtering out empty messages:

```swift
// WRONG:
let isEmpty = message.content.isEmpty
if !isEmpty { /* render */ }

// Tool messages created with empty content → filtered out → not rendered
```

**Fix:** Exception for toolExecution type:

```swift
// CORRECT:
let isEmpty = message.content.isEmpty && 
              message.type != .toolExecution  // ← ALWAYS show tool cards
if !isEmpty { /* render */ }
```

**Investigation Method:**
1. Added `CHAT_RENDER_LOOP` logging to track messages in ForEach
2. Discovered messages appearing in loop with `len=0` (empty content)
3. Cards only rendered when `len=176` (content filled in)
4. Traced to `isEmpty` filter blocking empty toolExecution messages

### Bug #2: Tool Card Titles Changing

**Symptom:** Title changed from "Image Generation" to "SUCCESS: Generated and displayed 1 image to the user"

**Root Cause:** `getOperationDisplayName()` parsed content BEFORE checking toolName:

```swift
// WRONG: Parse content first
if content.hasPrefix("SUCCESS: ") {
    return extractedAction  // "Generated and displayed..."
}
return getToolDisplayName(toolName)
```

**Fix:** Check toolName BEFORE parsing content:

```swift
// CORRECT: Prefer toolName over content
if let display = displayData {
    return display.actionDisplayName
}

if let toolName = toolName, !toolName.isEmpty {
    return getToolDisplayName(toolName)  // "Image Generation"
}

// Only parse content as fallback
if content.hasPrefix("SUCCESS: ") {
    return extractedAction
}
```

### Bug #3: SUCCESS Messages Hidden

**Symptom:** Output section empty or showing generic "Operation completed successfully" instead of actual results.

**Root Cause:** SUCCESS messages treated as "progress indicators" to be filtered:

```swift
// WRONG:
let isProgressMessage = message.content.hasPrefix("SUCCESS: ") || 
                        message.content.hasPrefix("→ ")
if !isProgressMessage {
    // Show output
} else {
    // Hide and show generic message
}
```

**Fix:** Only filter `"→ "` streaming updates, show SUCCESS messages:

```swift
// CORRECT:
let isProgressIndicator = message.content.hasPrefix("→ ")  // Only this
if !message.content.isEmpty && !isProgressIndicator {
    MarkdownText(message.content)  // Shows "SUCCESS: ..." as output
}
```

---

## Performance Optimizations

### 1. Synchronous Tool Message Sync

**Before:**
```swift
Task { @MainActor in
    conversation?.syncMessagesFromMessageBus()
}
```

**After:**
```swift
conversation?.syncMessagesFromMessageBus()  // Direct call
```

**Why:** MessageBus is already `@MainActor`, so async Task adds unnecessary delay.

### 2. Forced @Published Trigger

**Before:**
```swift
messages.append(message)
// @Published doesn't always trigger on array mutation
```

**After:**
```swift
messages.append(message)
messages = messages  // Force value change detection
```

**Why:** SwiftUI's `@Published` detects VALUE changes, not content mutations. Array reassignment guarantees trigger.

### 3. Tool Hierarchy Caching

```swift
@State private var cachedToolHierarchy: [UUID: [EnhancedMessage]] = [:]

.onChange(of: messages) { _, newMessages in
    cachedToolHierarchy = buildToolHierarchy(messages: newMessages)
}
```

**Why:** Building tool hierarchy is expensive (O(n²)). Cache and only rebuild when messages change, not on every render.

---

## Tool Card States

### ToolExecutionCard UI Structure (Running / Expanded / Error)

````mermaid
flowchart TB
    TEC[ToolExecutionCard]
    TEC --> Header[Header: icon, title, statusBadge, chevron]
    TEC --> Collapsed[Collapsed: Running... (shown when collapsed)]
    TEC --> Expanded[Expanded Details]
    Expanded --> Result[Result / Metadata]
    Expanded --> Ops[Operations (list)]
    Expanded --> Output[Output (MarkdownText)]
    Expanded --> Perf[Performance (duration)]

    Header -->|status == .error| ExpandedAuto[Auto-expand on error]
    ExpandedAuto --> Expanded
````

### Tool Execution State Machine

````mermaid
stateDiagram-v2
    [*] --> Queued
    Queued --> Running: addToolMessage(status = running)
    Running --> Success: updateMessage(status = success, content filled)
    Running --> Error: updateMessage(status = error)
    Success --> [*]
    Error --> [*]
````

**Note:** Error cards auto-expand via `.onAppear` logic (see `ToolExecutionCard.onAppear`).

---

## Testing Checklist

When modifying tool card code, verify:

- [ ] Tool cards appear **instantly** when tool execution starts (not when complete)
- [ ] Tool card titles remain **stable** (don't change to success/error messages)
- [ ] SUCCESS messages appear in **Output section** (not hidden)
- [ ] Empty tool cards show "Running..." or "Click to expand"
- [ ] Tool cards update to show results when tool completes
- [ ] Error tool cards auto-expand
- [ ] Child tool cards indent properly (30px left padding)
- [ ] Tool hierarchy builds correctly (parent-child relationships)
- [ ] Performance: No noticeable lag when adding tool messages

### Test Command

```bash
# Start SAM
make build-debug
pkill -9 SAM
nohup .build/Build/Products/Debug/SAM > sam_server.log 2>&1 & sleep 3

# Send message that uses tools (e.g., image generation)
# Watch logs in real-time
tail -f sam_server.log | grep -E "IMMEDIATE|TOOL_CARD_RENDERED|RENDER_LOOP"

# Expected timing:
# TS:XXXXX IMMEDIATE_RENDER: tool message id=ABC
# TS:XXXXX TOOL_CARD_RENDERED: tool=image_generation id=ABC
# Δt < 100ms between these logs
```

---

## Common Pitfalls

### ❌ DON'T: Filter toolExecution messages by isEmpty

```swift
// WRONG:
let isEmpty = message.content.isEmpty
if !isEmpty { /* render */ }
// Tool cards won't appear until content filled in!
```

### ✅ DO: Exception for toolExecution type

```swift
// CORRECT:
let isEmpty = message.content.isEmpty && 
              message.type != .toolExecution
if !isEmpty { /* render */ }
```

---

### ❌ DON'T: Parse content before checking toolName

```swift
// WRONG:
if content.hasPrefix("SUCCESS: ") {
    return extractedAction  // Title changes when content changes!
}
```

### ✅ DO: Prefer toolName over content parsing

```swift
// CORRECT:
if let toolName = toolName {
    return getToolDisplayName(toolName)  // Stable title
}
// Content parsing only as fallback
```

---

### ❌ DON'T: Hide SUCCESS messages

```swift
// WRONG:
if content.hasPrefix("SUCCESS: ") {
    return Text("Operation completed successfully")  // Generic!
}
```

### ✅ DO: Show SUCCESS messages as output

```swift
// CORRECT:
let isProgressIndicator = content.hasPrefix("→ ")  // Only hide these
if !isProgressIndicator {
    MarkdownText(content)  // Shows "SUCCESS: ..." 
}
```

---

### ❌ DON'T: Use async Task for tool message sync

```swift
// WRONG:
Task { @MainActor in
    conversation?.syncMessagesFromMessageBus()  // Adds delay!
}
```

### ✅ DO: Direct synchronous call (already on MainActor)

```swift
// CORRECT:
conversation?.syncMessagesFromMessageBus()  // Instant
```

---

## Related Documentation

- `docs/MESSAGE_CREATION_FLOW.md` - Overall message creation process
- `Sources/UserInterface/Chat/ChatWidget.swift` - Main chat UI
- `Sources/UserInterface/Chat/MessageView.swift` - Tool card UI
- `Sources/ConversationEngine/ConversationMessageBus.swift` - Message state management
- `Sources/APIFramework/AgentOrchestrator.swift` - Tool execution coordination

---

## Debugging Tools

### Enable Diagnostic Logging

Tool cards have extensive diagnostic logging:

```swift
// MessageBus
logger.debug("IMMEDIATE_RENDER: Forced array reassignment for tool message id=\(id)")
logger.debug("IMMEDIATE_SYNC: Tool message appended, syncing synchronously id=\(id)")

// ChatWidget
logger.info("[CHAT_RENDER_LOOP] Processing msg=\(id), len=\(content.count), type=\(type)")

// ToolExecutionCard
logger.error("TOOL_CARD_RENDERED: tool=\(toolName) id=\(id) toolCallId=\(toolCallId)")
```

**Search logs:**
```bash
grep -E "IMMEDIATE|TOOL_CARD_RENDERED|RENDER_LOOP" sam_server.log
```

### Measure Render Timing

```bash
# Extract timestamps and calculate deltas
grep "IMMEDIATE_RENDER\|TOOL_CARD_RENDERED" sam_server.log | \
  awk '{print $1, $2, $NF}' | \
  # Look for matching IDs and calculate time difference
```

**Expected:** < 100ms between IMMEDIATE_RENDER and TOOL_CARD_RENDERED

---

## Future Improvements

### 1. Structured Tool Results

Instead of parsing "SUCCESS: ..." strings, use structured metadata:

```swift
message.toolMetadata = [
    "action": "image_generation",
    "images_generated": "1",
    "output_path": "/path/to/image.png"
]
```

### 2. Real-Time Progress Updates

Show progress bars for long-running tools:

```swift
message.toolProgress = 0.65  // 65% complete
```

### 3. Tool Output Streaming

Stream tool output in real-time instead of showing only final result:

```swift
message.toolOutputChunks = [
    "Starting image generation...",
    "Loading model...",
    "Generating image..."
]
```

---

## Conclusion

Tool cards require careful attention to:
1. **Timing** - Instant rendering, not delayed until completion
2. **Stability** - Titles don't change, states update predictably
3. **Completeness** - Show all relevant output, don't hide important information

The architecture prioritizes **immediate user feedback** while maintaining **clean separation of concerns** between message creation (AgentOrchestrator), state management (MessageBus), and UI rendering (ChatWidget/ToolExecutionCard).

**Remember:** Tool cards are created EMPTY and filled in later. Any filtering logic must account for this lifecycle!
