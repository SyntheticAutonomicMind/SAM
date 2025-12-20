<!-- SPDX-License-Identifier: CC-BY-NC-4.0 -->
<!-- SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius) -->


# Conversation Persistence Flow

**Version:** 2.2  
**Last Updated:** December 1, 2025

## Overview

This document describes how SAM persists conversation data to disk, including the debounced save mechanism, file structure, and state synchronization between memory and persistent storage.

---

## Conversation File Structure

```
~/Library/Application Support/SAM/conversations/
├── active-conversation.json              # ID of currently active conversation
├── backups/                              # Automatic conversation backups
│   └── {conversation-id}_{timestamp}.json
└── {CONVERSATION_ID}/                    # Per-conversation directory
    ├── conversation.json                 # Conversation data + messages
    ├── tasks.json                        # Agent todo list
    └── .vectorrag/                       # RAG data (if documents imported)
        ├── chunks/
        └── index.sqlite
```

---

## Save Flow (Debounced)

```mermaid
sequenceDiagram
    participant MB as MessageBus
    participant CM as ConversationModel
    participant CMgr as ConversationManager
    participant FS as FileSystem

    Note over MB: User typing message...
    
    loop Multiple rapid changes
        MB->>MB: addUserMessage()
        MB->>MB: scheduleSave() - start 500ms timer
        
        Note over MB: Timer resets on each change
        
        MB->>MB: updateStreamingMessage()
        MB->>MB: scheduleSave() - reset timer
    end
    
    Note over MB: 500ms passes with no changes
    
    MB->>MB: saveMessages()
    MB->>CM: Update conversation.messages
    MB->>CMgr: saveConversations()
    
    CMgr->>CMgr: Check saveTimer (debounce)
    
    alt Save timer expired or nil
        CMgr->>CMgr: Start 500ms timer
        
        Note over CMgr: 500ms later (debounce)
        
        CMgr->>CMgr: performSave()
        
        loop For each conversation
            CMgr->>CM: toConversationData()
            CM-->>CMgr: ConversationData
            
            CMgr->>FS: Write conversation.json
            FS-->>CMgr: Success
        end
        
        CMgr->>FS: Write active-conversation.json
        FS-->>CMgr: Success
        
    else Save timer still active
        Note over CMgr: Skip save (debounce)
    end
```

---

## Immediate Save Flow

```mermaid
flowchart TD
    A[App Terminating] --> B[AppDelegate.applicationWillTerminate]
    B --> C[ConversationManager.cleanup]
    
    C --> D[Cancel debounce timer]
    D --> E[saveConversationsImmediately]
    
    E --> F{For Each Conversation}
    
    F --> G[MessageBus.saveMessagesImmediately]
    G --> H[Update conversation.messages]
    
    H --> I[ConversationModel.toConversationData]
    
    I --> J[Prepare JSON:<br/>- id, title, created, updated<br/>- messages array<br/>- settings<br/>- metadata]
    
    J --> K[Write to conversation.json]
    K --> L[Write active-conversation.json]
    
    L --> M[Flush disk buffers]
    M --> N[App terminates safely]
    
    style E fill:#FFD700
    style M fill:#90EE90
```

---

## Conversation Data Structure

### conversation.json Format

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "title": "SAM Development Discussion",
  "created": "2025-11-30T10:00:00Z",
  "updated": "2025-12-01T15:30:45Z",
  "messages": [
    {
      "id": "a1b2c3d4-...",
      "type": "user",
      "content": "Hello, SAM!",
      "isFromUser": true,
      "timestamp": "2025-11-30T10:01:00Z",
      "isPinned": true,
      "importance": 0.7
    },
    {
      "id": "e5f6g7h8-...",
      "type": "assistant",
      "content": "Hello! How can I help you today?",
      "isFromUser": false,
      "timestamp": "2025-11-30T10:01:02Z",
      "isPinned": false,
      "importance": 0.5,
      "performanceMetrics": {
        "firstTokenTime": 0.15,
        "tokensPerSecond": 45.3,
        "totalTokens": 150
      }
    },
    {
      "id": "i9j0k1l2-...",
      "type": "toolExecution",
      "content": "File contents:\n...",
      "isFromUser": false,
      "timestamp": "2025-11-30T10:02:00Z",
      "toolName": "file_read",
      "toolStatus": "success",
      "toolDuration": 0.05,
      "toolCallId": "call_abc123"
    }
  ],
  "settings": {
    "selectedModel": "github_copilot/gpt-4.1",
    "temperature": 0.7,
    "topP": 1.0,
    "maxTokens": null,
    "contextWindowSize": 128000,
    "selectedSystemPromptId": "00000000-0000-0000-0000-000000000001",
    "enableReasoning": false,
    "enableTools": true,
    "autoApprove": false,
    "enableTerminalAccess": false,
    "scrollLockEnabled": true,
    "useSharedData": false,
    "sharedTopicId": null,
    "sdNegativePrompt": "",
    "sdSteps": 25,
    "sdGuidanceScale": 8,
    "sdScheduler": "dpm++",
    "sdSeed": -1
  },
  "sessionId": "550e8400-e29b-41d4-a716-446655440000",
  "lastGitHubCopilotResponseId": "chatcmpl-abc123...",
  "isPinned": false,
  "workingDirectory": "/Users/user/SAM/SAM Development Discussion/",
  "isFromAPI": false,
  "folderId": null
}
```

### active-conversation.json Format

```json
{
  "activeConversationId": "550e8400-e29b-41d4-a716-446655440000"
}
```

---

## Load Flow

```mermaid
sequenceDiagram
    participant App
    participant CMgr as ConversationManager
    participant FS as FileSystem
    participant CM as ConversationModel
    participant MB as MessageBus

    App->>CMgr: init()
    CMgr->>CMgr: loadConversationsFromDisk()
    
    CMgr->>FS: List conversation directories
    FS-->>CMgr: [UUID-1, UUID-2, ...]
    
    loop For each conversation directory
        CMgr->>FS: Read conversation.json
        FS-->>CMgr: ConversationData
        
        CMgr->>CM: ConversationModel.from(data)
        CM-->>CMgr: ConversationModel instance
        
        CMgr->>MB: conversation.initializeMessageBus(self)
        MB->>MB: Load messages directly (avoid sync loop)
        MB->>CM: Set up subscription
        
        CMgr->>CMgr: Append to conversations array
    end
    
    CMgr->>FS: Read active-conversation.json
    FS-->>CMgr: activeConversationId
    
    CMgr->>CMgr: Find conversation by ID
    CMgr->>CMgr: Set as activeConversation
    
    CMgr-->>App: Ready
```

---

## Backup Flow

```mermaid
flowchart TD
    A[Conversation Save] --> B{Backup Enabled?}
    
    B -->|Yes| C[Check Backup Interval]
    B -->|No| Z[Skip Backup]
    
    C --> D{Time Since Last Backup > 1 hour?}
    
    D -->|Yes| E[Create Backup]
    D -->|No| Z
    
    E --> F[Generate Timestamp]
    F --> G[Backup Filename:<br/>{conversation-id}_{timestamp}.json]
    
    G --> H[Copy conversation.json to backups/]
    
    H --> I[Cleanup Old Backups]
    I --> J{Count Backups for Conversation}
    
    J --> K{> 10 backups?}
    K -->|Yes| L[Delete oldest backups]
    K -->|No| M[Keep all backups]
    
    L --> M
    M --> Z[Backup Complete]
    
    style E fill:#90EE90
    style L fill:#FFB6C1
```

---

## State Synchronization

### MessageBus → ConversationModel → Disk

```mermaid
flowchart LR
    A[MessageBus.messages] -->|1. objectWillChange.send| B[ConversationModel.messages]
    B -->|2. syncMessagesFromMessageBus| C[ConversationModel observes changes]
    C -->|3. scheduleSave 500ms| D[MessageBus.saveMessages]
    D -->|4. Update conversation.messages| E[ConversationManager.saveConversations]
    E -->|5. Debounce 500ms| F[Write to disk]
    
    style A fill:#87CEEB
    style F fill:#90EE90
```

### Performance Optimization: Delta Sync

Instead of copying entire messages array on each change:

```swift
// WRONG: Full array copy (slow during streaming)
conversation.messages = messageBus.messages  // 100+ messages copied

// RIGHT: Delta sync (fast, updates single message)
func updateMessage(at index: Int, with message: EnhancedMessage) {
    messages[index] = message
    objectWillChange.send()
}
```

---

## Edge Cases and Error Handling

### Corrupted Conversation File

```mermaid
flowchart TD
    A[Read conversation.json] --> B{Parse Success?}
    
    B -->|Yes| C[Load Conversation]
    B -->|No| D[Log Error]
    
    D --> E{Backup Exists?}
    
    E -->|Yes| F[Attempt Restore from Backup]
    E -->|No| G[Create Recovery Conversation]
    
    F --> H{Backup Parse Success?}
    
    H -->|Yes| I[Use Backup Data]
    H -->|No| G
    
    I --> C
    G --> J[Create New Conversation]
    J --> K[Title: Recovered Conversation]
    K --> L[Empty Messages]
    L --> C
    
    style F fill:#FFD700
    style G fill:#FFB6C1
```

### Conversation Deletion

```mermaid
sequenceDiagram
    participant UI
    participant CMgr as ConversationManager
    participant Conv as Conversation
    participant FS as FileSystem
    participant Mem as MemoryManager

    UI->>CMgr: deleteConversation(conversation, deleteWorkingDirectory=true)
    
    CMgr->>CMgr: Remove from conversations array
    
    CMgr->>FS: Check working directory
    FS-->>CMgr: Directory contents
    
    alt Directory NOT empty
        CMgr->>UI: Confirm deletion dialog
        UI-->>CMgr: User confirms/cancels
    end
    
    CMgr->>FS: Delete conversation.json
    CMgr->>FS: Delete tasks.json
    CMgr->>FS: Delete .vectorrag/
    
    alt deleteWorkingDirectory == true
        CMgr->>FS: Delete working directory
        FS-->>CMgr: Directory deleted
    end
    
    CMgr->>Mem: deleteConversationDatabase(conversationId)
    Mem->>FS: Delete memory.db
    
    CMgr->>CMgr: Update active conversation if needed
    CMgr->>CMgr: Save conversations
    
    CMgr-->>UI: Deletion complete
```

---

## Conversation Duplication

```mermaid
sequenceDiagram
    participant UI
    participant CMgr as ConversationManager
    participant Orig as Original Conversation
    participant New as New Conversation

    UI->>CMgr: duplicateConversation(original)
    
    CMgr->>Orig: toConversationData()
    Orig-->>CMgr: ConversationData
    
    CMgr->>CMgr: Generate new UUID
    CMgr->>CMgr: Generate unique title:<br/>Original Title (2)
    
    CMgr->>New: Create with new UUID
    New->>New: Copy messages
    New->>New: Copy settings
    New->>New: Clear session IDs
    New->>New: Clear GitHub response IDs
    New->>New: Reset timestamps
    
    CMgr->>CMgr: Append to conversations
    CMgr->>CMgr: Save conversations
    
    CMgr-->>UI: New conversation ready
```

---

## Performance Metrics

### Save Operations (Typical)

| Operation | Duration | Notes |
|-----------|----------|-------|
| MessageBus.saveMessages() | <1ms | Just sets conversation.messages |
| ConversationManager.saveConversations() | <1ms | Just schedules debounced save |
| Debounced Save (1 conversation) | 5-10ms | JSON encode + disk write |
| Debounced Save (10 conversations) | 50-100ms | Multiple JSON files |
| Immediate Save (app quit) | 50-150ms | Bypasses debounce |

### Load Operations (Typical)

| Operation | Duration | Notes |
|-----------|----------|-------|
| Load 1 conversation | 10-20ms | JSON decode |
| Load 10 conversations | 100-200ms | Multiple JSON files |
| Load 50 conversations | 500-1000ms | Sequential reads |
| Initialize MessageBus | 1-2ms | Per conversation |

### File Sizes (Approximate)

| Conversation Length | File Size | Notes |
|---------------------|-----------|-------|
| 10 messages | 5-10 KB | Simple text messages |
| 100 messages | 50-100 KB | Mixed text + tool calls |
| 1000 messages | 500KB-1MB | Long conversation |
| With large tool outputs | 5-10 MB | File contents in tool messages |

---

## Debouncing Strategy

### Why Debounce?

During streaming responses, messages update many times per second:

```
t=0.0s: "Hello"
t=0.1s: "Hello, I"
t=0.2s: "Hello, I'm"
t=0.3s: "Hello, I'm SAM"
t=0.4s: "Hello, I'm SAM."
```

Without debouncing: **5 disk writes in 0.4 seconds** (wasteful)  
With debouncing: **1 disk write 500ms after final update** (efficient)

### Debounce Implementation

```swift
private var saveTimer: Timer?

func scheduleSave() {
    saveTimer?.invalidate()
    saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
        self?.performSave()
    }
}

func saveConversationsImmediately() {
    saveTimer?.invalidate()
    saveTimer = nil
    performSave()
}
```

---

## Migration and Versioning

### Version Detection

```swift
struct ConversationData: Codable {
    // If version field missing, assume v1.0
    let version: String? = "2.2"
    
    // ... other fields
}
```

### Migration Path

When loading conversation with older version:

```mermaid
flowchart TD
    A[Load conversation.json] --> B{Detect Version}
    
    B -->|v1.0| C[Apply v1.0 → v2.0 Migration]
    B -->|v2.0| D[Apply v2.0 → v2.1 Migration]
    B -->|v2.1| E[Apply v2.1 → v2.2 Migration]
    B -->|v2.2| F[Current Version]
    
    C --> D
    D --> E
    E --> F
    
    F --> G[Save with Current Version]
    
    style C fill:#FFD700
    style D fill:#FFD700
    style E fill:#FFD700
    style F fill:#90EE90
```

Example migration:

```swift
if data.version == nil || data.version == "1.0" {
    // Add default values for new fields
    data.settings.scrollLockEnabled = true
    data.settings.enableDynamicIterations = false
    data.version = "2.0"
}
```

---

## Related Documentation

- [ConversationEngine Subsystem](../subsystems/CONVERSATION_ENGINE.md)
- [Message Flow](message_flow.md)
- [Memory System Specification](../MEMORY_AND_INTELLIGENCE_SPECIFICATION.md)
