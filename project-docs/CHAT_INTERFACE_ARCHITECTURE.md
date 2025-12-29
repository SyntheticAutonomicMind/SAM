<!-- SPDX-License-Identifier: CC-BY-NC-4.0 -->
<!-- SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius) -->


# SAM Chat Interface Architecture Design

## Overview

This document outlines the chat interface architecture for SAM, designed to match SAM 1.0's quality and user experience while leveraging the completed streaming implementation.

## Component Hierarchy

### 1. MainChatView (Root Component)
**Purpose**: Main chat window with navigation and conversation management
**Location**: `Sources/UserInterface/Chat/MainChatView.swift`
**Pattern**: NavigationSplitView with sidebar + content layout

```swift
struct MainChatView: View {
    // Sidebar: Conversation list with search and filters
    // Content: Active conversation display
    // Toolbar: New conversation, settings, inspector toggle
}
```

**Key Features**:
- NavigationSplitView layout matching SAM 1.0
- Conversation list sidebar with search/filtering
- Active conversation display area
- Toolbar with new chat, settings, inspector actions
- Integration with existing EndpointManager for model access

### 2. ConversationListView (Sidebar Component)
**Purpose**: Display and manage conversation history
**Location**: `Sources/UserInterface/Chat/ConversationListView.swift`
**Pattern**: List with custom conversation rows

```swift
struct ConversationListView: View {
    // List of conversations with titles and metadata
    // Search and filter functionality
    // New conversation creation
    // Conversation selection management
}
```

**Key Features**:
- Conversation list with titles and timestamps
- Search and filtering capabilities
- Active conversation highlighting
- Context menu actions (delete, export, rename)
- Drag and drop organization

### 3. EnhancedConversationView (Main Content)
**Purpose**: Display active conversation with messages and input
**Location**: `Sources/UserInterface/Chat/EnhancedConversationView.swift`
**Pattern**: VStack with header, messages, input areas

```swift
struct EnhancedConversationView: View {
    // Conversation header with title and status
    // Scrollable message list with auto-scroll
    // Enhanced message input area
    // Streaming status indicators
}
```

**Key Features**:
- Enhanced header matching SAM 1.0 design
- Message list with proper auto-scrolling
- Integration with existing ChatWidget streaming
- Status indicators for processing/streaming
- Model selection and configuration UI

### 4. MessageBubbleView (Message Display)
**Purpose**: Individual message display with rich formatting
**Location**: `Sources/UserInterface/Chat/MessageBubbleView.swift`
**Pattern**: HStack with role-based alignment and styling

```swift
struct MessageBubbleView: View {
    // Role-based message alignment (user right, assistant left)
    // Rich markdown rendering
    // Hover actions (edit, copy, regenerate, delete)
    // Timestamp and metadata display
}
```

**Key Features**:
- User messages: right-aligned, blue styling
- Assistant messages: left-aligned, gray styling  
- Full markdown support with syntax highlighting
- Hover actions: edit, regenerate, copy, delete
- Message metadata: tokens, timestamp, formatting indicators
- Copy and text selection support

### 5. StreamingMessageInput (Input Component)
**Purpose**: Enhanced message input with streaming integration
**Location**: `Sources/UserInterface/Chat/StreamingMessageInput.swift`
**Pattern**: Enhanced TextEditor with send controls

```swift
struct StreamingMessageInput: View {
    // Multi-line text input with auto-resize
    // Send button with streaming state management
    // Model/provider selection integration
    // Attachment support preparation
}
```

**Key Features**:
- Multi-line text input with proper sizing
- Send button with streaming state management
- Integration with EndpointManager for model selection
- Keyboard shortcuts and accessibility
- Placeholder for future attachment support

### 6. Session Intelligence Toolbar (Context Visibility)
**Purpose**: Provide visibility into agent's knowledge and context state
**Location**: `Sources/UserInterface/Chat/ChatWidget.swift` (sessionIntelligencePanel)
**Pattern**: VStack with three distinct sections

```swift
struct SessionIntelligencePanel: View {
    // Memory Status section
    // Context Management section  
    // Enhanced Search section with multi-source capabilities
}
```

**Key Features**:

**Memory Status Section**:
- Total stored memories with type breakdown (interactions, facts, preferences, etc.)
- Memory access statistics (total accesses, average importance)
- Memory span indicator (days between oldest and newest memories)
- Clear memories action button

**Context Management Section**:
- Active context window usage (current tokens / max tokens with percentage)
- YaRN compression status indicator (compression ratio, active/inactive state)
- Archived context statistics (chunk count, total archived tokens)
- Archive topic preview (top 5 topics from archived chunks)

**Enhanced Multi-Source Search**:
- **Stored Search**: Vector RAG semantic search across stored memories in database
- **Active Search**: Text matching in current conversation messages (real-time context)
- **Archive Search**: Query archived context chunks via ContextArchiveManager
- **Combined Search**: Parallel search across all three sources with unified results
- Source-specific toggle controls (enable/disable each search mode independently)
- Result display with source badges (STORED/ACTIVE/ARCHIVE)
- Color-coded results (green for stored, blue for active, orange for archive)

**Integration Points**:
- `ConversationManager.getActiveConversationMemoryStats()` - Memory statistics
- `ConversationManager.getActiveConversationArchiveStats()` - Archive data
- `ConversationManager.getYaRNContextStats()` - Context window statistics
- `MemoryManager.retrieveRelevantMemories()` - Stored search
- `ContextArchiveManager.recallHistory()` - Archive search
- Active message search via conversation.messages array

**User Experience**:
- Collapsible panel accessed via brain icon in toolbar
- Real-time updates when switching conversations or shared topics
- Clear visual separation between sections with dividers
- Tooltips and help text for all interactive elements
- Graceful degradation when data unavailable (shows "No data" messages)

## Integration with Existing Components

### Leveraging Completed Streaming Implementation

**EndpointManager Integration**:
- `reloadProviderConfigurations()` for UI consistency
- `processStreamingChatCompletion()` for streaming responses
- Provider configuration loading patterns established

**ChatWidget Streaming Patterns**:
- Delta content append strategy for efficient streaming updates
- Performance tracking and error handling
- Model loading consistency (36 models accessible)

### Data Flow Architecture

```
User Input → StreamingMessageInput → EndpointManager → Provider API
         ↓
         Streaming Response → MessageBubbleView → ConversationView
         ↓
         Conversation Persistence → ConversationListView Update
```

## Visual Design Language

### Matching SAM 1.0 Quality

**Message Bubble Styling**:
- User: Blue accent, right-aligned, rounded corners
- Assistant: System background, left-aligned, SAM branding
- System: Purple accent, center-aligned, minimal styling

**Layout Patterns**:
- Consistent spacing: 12pt padding, 8pt item spacing
- Typography: System font with proper line spacing
- Colors: System semantic colors with theme support
- Animation: Smooth transitions, auto-scroll behavior

**Interaction Patterns**:
- Hover states for message actions
- Context menus for conversation management  
- Keyboard shortcuts for power users
- VoiceOver accessibility support

## Implementation Strategy

### Phase 1: Core Components
1. **MainChatView**: Basic NavigationSplitView layout
2. **MessageBubbleView**: User and assistant message display
3. **StreamingMessageInput**: Basic input with send functionality
4. **Integration**: Connect with existing EndpointManager streaming

### Phase 2: Enhanced Features  
1. **ConversationListView**: Conversation management sidebar
2. **EnhancedConversationView**: Full conversation display with headers
3. **Message Actions**: Edit, regenerate, copy, delete functionality
4. **Search and Filtering**: Conversation and message search

### Phase 3: Advanced Features
1. **Markdown Rendering**: Rich text display with syntax highlighting
2. **Conversation Persistence**: Full conversation history management
3. **Export/Import**: Conversation data management
4. **Advanced Configuration**: Model settings, temperature, context

## Success Criteria

The chat interface succeeds when:
- **Visual Match**: Interface is visually indistinguishable from SAM 1.0
- **Streaming Integration**: Real-time responses using existing streaming implementation
- **User Experience**: Navigation and interaction feels identical to SAM 1.0
- **Performance**: Responsive UI with smooth animations and transitions
- **Accessibility**: Full VoiceOver support and keyboard navigation
- **Reliability**: No crashes, memory leaks, or UI freezing

## Technical Notes

**Architecture Patterns Learned from SAM 1.0**:
- NavigationSplitView for main layout structure
- Timer-based message refreshing during processing
- Debouncing and state guards to prevent UI conflicts
- ChatManager pattern for conversation state management
- StreamingChatViewModel for UI state management

**Critical Implementation Details**:
- Always call `reloadProviderConfigurations()` for UI/API consistency
- Use delta.content append strategy for streaming
- Implement proper message ordering with timestamp + ID sorting
- Add comprehensive code comments explaining architectural decisions
- Maintain existing streaming quality while adding UI enhancements

This architecture ensures pixel-perfect recreation of SAM 1.0's interface quality while building on the solid streaming foundation already completed.