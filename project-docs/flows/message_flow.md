<!-- SPDX-License-Identifier: CC-BY-NC-4.0 -->
<!-- SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius) -->


# Message Flow

**Version:** 2.4  
**Last Updated:** December 5, 2025

## Overview

This document describes the complete message flow in SAM, from user input through AI processing to display, including streaming updates, tool execution, persistence, and context reminders.

---

## Complete Message Lifecycle

```mermaid
flowchart TD
    A[User Types Message] --> B[ChatWidget captures input]
    B --> C[ConversationModel.messageBus]
    
    C --> D[MessageBus.addUserMessage]
    D --> E[Create EnhancedMessage]
    E --> F[Calculate importance score]
    F --> G[Auto-pin if first 3 user messages]
    G --> H[Append to messages array]
    H --> I[Update messageCache]
    I --> J[scheduleSave - 500ms debounce]
    J --> K[syncMessagesFromMessageBus]
    K --> L[ChatWidget re-renders]
    
    L --> M[AgentOrchestrator.callLLM]
    M --> M1[Inject Context Reminders]
    M1 --> N[EndpointManager.processStreamingChatCompletion]
    N --> O[Provider API call]
    
    O --> P{Streaming Response}
    
    P -->|Chunk| Q[MessageBus.updateStreamingMessage]
    Q --> R[Delta sync to ConversationModel]
    R --> S[ChatWidget updates in real-time]
    S --> P
    
    P -->|Complete| T[MessageBus.completeStreamingMessage]
    T --> U[Set isStreaming=false]
    U --> V[Add performance metrics]
    V --> W[scheduleSave]
    W --> X[Final UI update]
    
    X --> Y{Tool Calls?}
    Y -->|Yes| Z[Execute Tools]
    Y -->|No| AA[Message Complete]
    
    Z --> AB[MessageBus.addToolMessage]
    AB --> AC[Display tool result]
    AC --> M
    
    style D fill:#87CEEB
    style Q fill:#FFD700
    style T fill:#90EE90
```

---

## Message Bus Architecture

### Single Source of Truth Pattern

```mermaid
classDiagram
    class MessageBus {
        +messages: [EnhancedMessage]
        -messageCache: [UUID: Int]
        -saveTimer: Timer?
        +addUserMessage() UUID
        +addAssistantMessage() UUID
        +updateStreamingMessage(id, content)
        +completeStreamingMessage(id)
        -scheduleSave()
        -notifyConversationOfChanges()
    }
    
    class ConversationModel {
        +messages: [EnhancedMessage]
        +messageBus: MessageBus?
        +syncMessagesFromMessageBus()
        +updateMessage(at, with)
    }
    
    class ChatWidget {
        +observes messages
        +displays real-time updates
    }
    
    MessageBus --> ConversationModel : syncs to
    ConversationModel --> ChatWidget : observes
    
    note for MessageBus "Single source of truth\nAll message operations\ngo through MessageBus"
    
    note for ConversationModel "Read-only mirror\nUpdated by MessageBus\nNever modified directly"
```

---

## Streaming Message Flow

```mermaid
sequenceDiagram
    participant UI as ChatWidget
    participant CM as ConversationModel
    participant MB as MessageBus
    participant AO as AgentOrchestrator
    participant EM as EndpointManager
    participant P as Provider

    UI->>CM: Send button clicked
    CM->>MB: addUserMessage(content)
    MB->>MB: Create user message (isPinned auto-set)
    MB->>CM: syncMessagesFromMessageBus()
    CM->>UI: Display user message
    
    UI->>AO: Process message
    AO->>MB: addAssistantMessage("", isStreaming=true)
    MB->>MB: Create empty streaming message
    MB->>CM: syncMessagesFromMessageBus()
    CM->>UI: Display empty assistant message
    
    AO->>EM: processStreamingChatCompletion(request)
    EM->>P: API call with streaming
    
    loop For each chunk
        P-->>EM: Stream chunk
        EM-->>AO: Chunk received
        
        AO->>MB: updateStreamingMessage(id, accumulatedContent)
        
        activate MB
        MB->>MB: Find message in cache O(1)
        MB->>MB: Create updated message
        MB->>MB: messages[index] = updated
        MB->>MB: scheduleSave() - reset timer
        MB->>CM: notifyConversationOfMessageUpdate(id, index, msg)
        deactivate MB
        
        activate CM
        CM->>CM: updateMessage(at: index, with: message)
        CM->>CM: objectWillChange.send()
        CM->>UI: Delta update (no array copy)
        deactivate CM
        
        UI->>UI: Render updated content
    end
    
    P-->>EM: Stream complete
    EM-->>AO: Completion
    
    AO->>MB: completeStreamingMessage(id, metrics)
    MB->>MB: Set isStreaming=false
    MB->>MB: Trim whitespace
    MB->>MB: Add performance metrics
    MB->>MB: scheduleSave()
    MB->>CM: syncMessagesFromMessageBus()
    CM->>UI: Final render
```

---

## Context Reminder Injection

Context reminders ensure the agent maintains awareness of user instructions, todo status, and imported documents across multi-turn conversations. Following VS Code Copilot's pattern, reminders are injected **RIGHT BEFORE** the final user message for maximum salience.

### Injection Sequence

```mermaid
sequenceDiagram
    participant AO as AgentOrchestrator
    participant MPI as MiniPromptReminderInjector
    participant TRI as TodoReminderInjector
    participant DRI as DocumentImportReminderInjector
    participant LLM

    AO->>AO: Build conversation messages
    
    Note over AO: Before adding user message...
    
    AO->>MPI: formatMiniPromptReminder(messages)
    MPI-->>AO: <miniPromptReminder> or nil
    
    AO->>TRI: formatTodoReminder(conversationId)
    TRI-->>AO: <todoList> or nil
    
    AO->>DRI: formatDocumentReminder(conversationId)
    DRI-->>AO: document list or nil
    
    AO->>AO: Wrap each in <system-reminder>
    AO->>AO: Add reminders as user-role messages
    AO->>AO: Add final user message
    
    AO->>LLM: Send complete message array
```

### Reminder Order

1. **MiniPromptReminderInjector** - User's custom instructions (mini prompts)
2. **TodoReminderInjector** - Current todo list with progress rules
3. **DocumentImportReminderInjector** - Imported documents reminder
4. **User Message** - The actual user query

### Why Right Before User Message?

Positioning reminders immediately before the user's query ensures:
- **Maximum salience** - Most recent context has highest attention
- **VS Code compatibility** - Matches VS Code Copilot's `<TodoListContextPrompt>` pattern
- **Prevents "forgetting"** - Long research sessions maintain user instructions

---

## Tool Execution Flow

```mermaid
sequenceDiagram
    participant AO as AgentOrchestrator
    participant MB as MessageBus
    participant MCPMgr as MCPManager
    participant Tool
    participant FS as FileSystem

    AO->>AO: Parse tool call from LLM
    AO->>MB: addToolMessage(name, status=running, details="Executing...")
    MB->>MB: Create tool message with spinner
    
    AO->>MCPMgr: executeTool(name, parameters)
    MCPMgr->>Tool: execute(parameters)
    
    alt Tool Success
        Tool->>FS: Perform operation
        FS-->>Tool: Result
        Tool-->>MCPMgr: Success result
        MCPMgr-->>AO: ToolResult(success=true, content)
        
        AO->>MB: updateMessage(id, status=success, content)
        MB->>MB: Update with green checkmark ✅
        
    else Tool Failure
        Tool-->>MCPMgr: Error
        MCPMgr-->>AO: ToolResult(success=false, error)
        
        AO->>MB: updateMessage(id, status=error, content)
        MB->>MB: Update with red X ❌
    end
    
    MB->>MB: Add duration metadata
    MB->>MB: scheduleSave()
    
    AO->>AO: Continue LLM interaction with tool result
```

---

## Message Types and Structure

### EnhancedMessage Structure

```swift
struct EnhancedMessage: Identifiable, Codable {
    let id: UUID
    let type: MessageType                    // user, assistant, system, thinking, toolExecution
    var content: String
    let isFromUser: Bool
    let timestamp: Date
    
    // Tool execution fields
    var toolName: String?
    var toolStatus: ToolStatus?              // running, success, error
    var toolDetails: [String]?
    var toolDuration: TimeInterval?
    var toolCallId: String?
    
    // Performance metrics
    var performanceMetrics: MessagePerformanceMetrics?
    
    // Streaming state
    var isStreaming: Bool
    
    // Importance/context
    var isPinned: Bool
    var importance: Double                    // 0.0-1.0
    
    // Content parts (multimodal)
    var contentParts: [MessageContentPart]?   // Text, image, code, etc.
}

enum MessageType: String, Codable {
    case user
    case assistant
    case system
    case thinking                             // Extended thinking mode
    case toolExecution
}

enum ToolStatus: String, Codable {
    case running
    case success
    case error
}

struct MessagePerformanceMetrics: Codable {
    let firstTokenTime: TimeInterval?         // Time to first token
    let tokensPerSecond: Double?              // Generation speed
    let totalTokens: Int?                     // Total tokens generated
    let inputTokens: Int?                     // Prompt tokens
    let outputTokens: Int?                    // Completion tokens
}
```

---

## Message Cache Performance

### Cache Lookup Algorithm

```swift
private var messageCache: [UUID: Int] = [:]  // id → index

// O(1) lookup instead of O(n) search
func updateStreamingMessage(id: UUID, content: String) {
    guard let index = messageCache[id] else {
        logger.error("Message not found in cache: \(id)")
        return
    }
    
    // Direct array access - very fast
    var updated = messages[index]
    updated.content = content
    messages[index] = updated
    
    // No need to rebuild cache - index unchanged
}
```

**Performance Comparison:**

| Messages | O(n) Search | O(1) Cache | Speedup |
|----------|-------------|------------|---------|
| 10 | 5 comparisons | 1 lookup | 5× |
| 100 | 50 comparisons | 1 lookup | 50× |
| 1000 | 500 comparisons | 1 lookup | 500× |

### Cache Maintenance

```swift
func addMessage(_ message: EnhancedMessage) {
    let index = messages.count
    messages.append(message)
    messageCache[message.id] = index
}

func removeMessage(id: UUID) {
    guard let index = messageCache[id] else { return }
    messages.remove(at: index)
    rebuildCache()  // Required after removal
}

private func rebuildCache() {
    messageCache.removeAll()
    for (index, message) in messages.enumerated() {
        messageCache[message.id] = index
    }
}
```

---

## Importance Scoring Algorithm

### Calculation Logic

```swift
func calculateMessageImportance(text: String, isUser: Bool) -> Double {
    var importance = isUser ? 0.7 : 0.5  // Base importance
    
    // 1. Questions from assistant (agent wants to remember)
    if !isUser && containsQuestion(text) {
        importance = max(importance, 0.85)
    }
    
    // 2. Constraints/requirements (critical context)
    if containsConstraints(text) {
        importance = max(importance, 0.9)
    }
    
    // 3. Decisions/confirmations
    if isDecision(text) && text.count < 200 {
        importance = max(importance, 0.85)
    }
    
    // 4. Priority/focus shifts
    if containsPriorityKeywords(text) {
        importance = max(importance, 0.85)
    }
    
    // 5. Small talk (low value)
    if isSmallTalk(text) {
        importance = 0.3
    }
    
    // 6. Boost for longer user messages
    if isUser && text.count > 300 {
        importance = min(importance + 0.1, 1.0)
    }
    
    return importance
}
```

### Importance Use Cases

1. **Context Retrieval**: Higher importance messages retrieved first
2. **Context Pruning**: Lower importance messages dropped when at token limit
3. **Memory Storage**: Higher importance → more likely to be remembered long-term
4. **Summarization**: Focus summaries on high-importance messages

---

## Auto-Pin Logic

First 3 user messages automatically pinned:

```swift
func addUserMessage(content: String, isPinned: Bool? = nil) -> UUID {
    let currentUserCount = messages.filter { $0.isFromUser }.count
    
    // Auto-pin first 3 user messages (unless explicitly overridden)
    let shouldPin = isPinned ?? (currentUserCount < 3)
    
    let message = EnhancedMessage(
        id: UUID(),
        type: .user,
        content: content,
        isFromUser: true,
        timestamp: Date(),
        isPinned: shouldPin,
        importance: calculateMessageImportance(content, isUser: true)
    )
    
    addMessage(message)
    return message.id
}
```

**Rationale:**
- Initial messages contain task description and constraints
- Agents need guaranteed access to original request
- Prevents context loss in long conversations

---

## Delta Sync vs Full Sync

### Full Sync (Old Pattern - Inefficient)

```swift
// WRONG: Copy entire array on every update
conversation.messages = messageBus.messages  // 1000 messages × 50 updates/sec = 50,000 copies/sec

// SwiftUI re-renders entire message list
ForEach(conversation.messages) { message in
    MessageView(message: message)  // All 1000 views recreated
}
```

### Delta Sync (Current Pattern - Efficient)

```swift
// RIGHT: Update single message
func updateMessage(at index: Int, with message: EnhancedMessage) {
    messages[index] = message
    objectWillChange.send()  // Only changed row re-renders
}

// SwiftUI re-renders only changed message
ForEach(conversation.messages) { message in
    MessageView(message: message)  // Only 1 view recreated
}
```

**Performance Impact:**

| Streaming Speed | Full Sync CPU | Delta Sync CPU | Improvement |
|----------------|---------------|----------------|-------------|
| 10 chunks/sec | 15% | 2% | 7.5× |
| 50 chunks/sec | 75% | 5% | 15× |
| 100 chunks/sec | Drops frames | 8% | 12.5× |

---

## Message Persistence Timeline

```mermaid
gantt
    title Message Save Timeline (Debounced)
    dateFormat  HH:mm:ss.SSS
    axisFormat  %S.%Ls
    
    section Message Updates
    updateStreamingMessage (chunk 1)   :milestone, m1, 00:00:00.000, 0ms
    updateStreamingMessage (chunk 2)   :milestone, m2, 00:00:00.100, 0ms
    updateStreamingMessage (chunk 3)   :milestone, m3, 00:00:00.200, 0ms
    updateStreamingMessage (chunk 4)   :milestone, m4, 00:00:00.300, 0ms
    updateStreamingMessage (chunk 5)   :milestone, m5, 00:00:00.400, 0ms
    
    section Debounce Timer
    Timer starts                        :active, t1, 00:00:00.000, 500ms
    Timer resets (chunk 2)             :crit, t2, 00:00:00.100, 500ms
    Timer resets (chunk 3)             :crit, t3, 00:00:00.200, 500ms
    Timer resets (chunk 4)             :crit, t4, 00:00:00.300, 500ms
    Timer resets (chunk 5)             :crit, t5, 00:00:00.400, 500ms
    Timer expires                       :milestone, t6, 00:00:00.900, 0ms
    
    section Disk Operations
    Save to disk                        :done, save, 00:00:00.900, 10ms
```

**Result:** 5 rapid updates → 1 disk write (5× reduction)

---

## Multimodal Message Support

### Content Parts Structure

```swift
enum MessageContentPart: Codable {
    case text(String)
    case image(ImageContent)
    case code(CodeContent)
    case file(FileContent)
    
    struct ImageContent: Codable {
        let url: String?                   // Local file or HTTP URL
        let base64Data: String?            // Embedded image data
        let mimeType: String               // image/png, image/jpeg
        let width: Int?
        let height: Int?
    }
    
    struct CodeContent: Codable {
        let code: String
        let language: String               // swift, python, etc.
        let filename: String?
    }
    
    struct FileContent: Codable {
        let path: String
        let filename: String
        let mimeType: String
    }
}
```

### Multimodal Message Flow

```mermaid
sequenceDiagram
    participant UI
    participant MB as MessageBus
    participant SD as StableDiffusion

    UI->>MB: User sends "generate a cat image"
    MB->>MB: addUserMessage(content, contentParts=[text])
    
    UI->>SD: generateImage(prompt="a cat")
    SD-->>UI: ImageURL
    
    UI->>MB: addAssistantMessage(content="Generated image:", contentParts=[text, image])
    
    MB->>MB: Create message with mixed content
    MB->>MB: Persist imageURL in conversation.json
    
    Note over MB: When conversation reloads...
    
    MB->>MB: Load from disk
    MB->>MB: Reconstruct contentParts with imageURL
    MB->>UI: Display text + image
```

---

## Error Handling

### Message Creation Failures

```swift
func addAssistantMessage(content: String) -> UUID {
    // Validate content
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        logger.warning("Attempted to add empty assistant message")
        return UUID()  // Return dummy ID, don't add message
    }
    
    // Create and add message
    let message = EnhancedMessage(...)
    addMessage(message)
    return message.id
}
```

### Streaming Update Failures

```swift
func updateStreamingMessage(id: UUID, content: String) {
    guard let index = messageCache[id] else {
        logger.error("CRITICAL: Message \(id) not found in cache during streaming")
        
        // Recovery: Rebuild cache and retry
        rebuildCache()
        
        guard let recoveredIndex = messageCache[id] else {
            logger.error("CRITICAL: Message \(id) not in messages array either")
            return
        }
        
        // Continue with recovered index
        messages[recoveredIndex].content = content
        return
    }
    
    // Normal path
    messages[index].content = content
}
```

---

## Performance Monitoring

### Key Metrics

```swift
struct MessageBusMetrics {
    var messagesAdded: Int
    var messagesUpdated: Int
    var streamingUpdates: Int
    var cacheMisses: Int
    var savesScheduled: Int
    var savesExecuted: Int
    var averageUpdateTime: TimeInterval
    var peakUpdateTime: TimeInterval
}
```

---

## Streaming TTS Integration

When text-to-speech is enabled, the message flow integrates with the Sound subsystem to speak responses as they stream.

### Streaming TTS Flow

```mermaid
sequenceDiagram
    participant LLM as AI Provider
    participant AO as AgentOrchestrator
    participant MB as MessageBus
    participant UI as ChatWidget
    participant SSS as SpeechSynthesisService

    Note over AO: TTS enabled for conversation
    
    AO->>MB: addAssistantMessage(isStreaming=true)
    MB->>UI: Display empty message
    
    loop For each streaming chunk
        LLM-->>AO: Text chunk
        AO->>MB: updateStreamingMessage(id, content)
        MB->>UI: Update message display
        
        AO->>AO: Detect complete sentence
        
        alt Complete sentence found
            AO->>SSS: queueSentence(sentence)
            SSS->>SSS: Add to sentenceQueue
            
            alt Not currently speaking
                SSS->>SSS: processNextSentence()
                Note over SSS: NSSpeechSynthesizer speaks
            end
        end
    end
    
    LLM-->>AO: Stream complete
    AO->>MB: completeStreamingMessage(id)
    MB->>UI: Final render
    
    AO->>SSS: finishStreaming()
    
    loop While queue not empty
        SSS-->>SSS: didFinishSpeaking callback
        SSS->>SSS: processNextSentence()
    end
    
    SSS-->>AO: onSpeakingFinished()
```

### Sentence Detection

During streaming, sentences are detected by looking for:
- Period followed by space or end of chunk (`. `)
- Question mark (`?`)
- Exclamation point (`!`)
- Newline after substantial text

```swift
// Simplified sentence detection logic
func detectCompleteSentence(in text: String) -> (sentence: String, remainder: String)? {
    let sentenceEndings = [". ", "? ", "! ", ".\n", "?\n", "!\n"]
    
    for ending in sentenceEndings {
        if let range = text.range(of: ending) {
            let sentence = String(text[..<range.upperBound])
            let remainder = String(text[range.upperBound...])
            return (sentence, remainder)
        }
    }
    return nil
}
```

### TTS Queue Management

The SpeechSynthesisService maintains a queue of sentences:

1. **queueSentence()**: Adds sentence to queue, starts speaking if idle
2. **processNextSentence()**: Called after each sentence finishes
3. **finishStreaming()**: Marks streaming complete, calls completion after queue empties
4. **clearQueue()**: Cancels all pending speech (for stop button)

### Voice Settings Integration

TTS respects user preferences from AudioDeviceManager:
- Selected voice identifier
- Speech rate multiplier
- Output device (system default or selected)

Settings changes take effect on the next queued sentence.

---

## Performance Monitoring

### Performance Logging

```swift
let perfStart = CFAbsoluteTimeGetCurrent()

// Perform operation
updateStreamingMessage(id: messageId, content: chunk)

let duration = CFAbsoluteTimeGetCurrent() - perfStart

if duration > 0.016 {  // > 16ms (60 FPS threshold)
    logger.warning("Slow message update: \(duration * 1000)ms")
}
```

---

## Related Documentation

- [ConversationEngine Subsystem](../subsystems/CONVERSATION_ENGINE.md)
- [Sound Subsystem](../subsystems/SOUND.md)
- [Conversation Persistence Flow](conversation_persistence.md)
- [Message Flow Redesign Specification](../MESSAGE_FLOW_AND_TOOLS_REDESIGN.md)
