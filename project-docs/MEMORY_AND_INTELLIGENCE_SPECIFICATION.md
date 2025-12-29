<!-- SPDX-License-Identifier: CC-BY-NC-4.0 -->
<!-- SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius) -->


# SAM Memory and Intelligence Specification

## Overview

The Memory and Intelligence System forms the core of SAM, providing contextual conversation memory, intelligent reasoning, and adaptive learning through a user-friendly interface that makes complex AI capabilities accessible through natural conversation.

## Design Philosophy

### User Experience Principles
- **Invisible Complexity**: Advanced memory and intelligence capabilities work transparently
- **Natural Interaction**: Users access all features through conversational interface
- **Contextual Awareness**: System remembers and uses conversation context appropriately
- **Adaptive Intelligence**: System learns user preferences and adapts behavior

### Technical Principles
- **Hardware Optimization**: Full utilization of Apple Silicon capabilities
- **Modular Architecture**: Clean separation between components
- **Performance First**: Efficient memory management and fast response times
- **Privacy Focused**: Context isolation and configurable data retention

## Core Architecture

### Memory System Components

```swift
// Enhanced memory architecture with Vector RAG and YaRN integration
class ConversationManager {
    // Core memory systems
    public let memoryManager = MemoryManager()
    public let vectorRAGService: VectorRAGService
    public let yaRNContextProcessor: YaRNContextProcessor
    
    // Context-isolated memory for individual conversations
    func getConversationContext() async -> ConversationContext
    func addMessage(_ message: UserMessage) async
    func extractRelevantContext(for query: String) async -> RelevantContext
}

// Vector RAG Service for semantic document processing (IMPLEMENTED - 665 lines)
class VectorRAGService {
    private let embeddingGenerator: EmbeddingGenerator
    private let documentChunker: DocumentChunker
    
    // Sophisticated document processing and retrieval
    func ingestDocument(_ document: RAGDocument) async throws -> DocumentIngestionResult
    func semanticSearch(query: String, limit: Int = 20, similarityThreshold: Double = 0.2) async throws -> [SemanticSearchResult]
    func retrieveAugmentedContext(for query: String, conversationId: UUID) async throws -> RAGContext
}

// YaRN Context Processor for dynamic context management (IMPLEMENTED - 609 lines) 
class YaRNContextProcessor {
    private let config: YaRNConfig // Supports 8K-65K token windows
    
    // Intelligent context window management
    func processConversationContext(messages: [Message], conversationId: UUID, targetTokenCount: Int?) async throws -> ProcessedContext
    func applyYaRNCompression(_ messages: [Message], targetTokens: Int) async throws -> CompressedContext
    func analyzeMessageImportance(_ messages: [Message]) async -> [MessageImportance]
}

// Enhanced Memory Manager with Vector RAG integration
class MemoryManagerAdapter {
    private let vectorRAGService: VectorRAGService?
    
    // Enhanced semantic search with RAG fallback
    func searchMemories(query: String, limit: Int) async throws -> [any MemoryEntry] {
        // Try Vector RAG semantic search first for enhanced capabilities
        // Fall back to traditional cross-conversation search if needed
    }
}
```

### Intelligence Engine

```swift
// Core reasoning and task management
class IntelligenceEngine {
    private let taskPlanner: ConversationalTaskPlanner
    private let reasoningEngine: ContextualReasoningEngine
    private let adaptiveSystem: UserAdaptationSystem
    
    // Natural conversation processing
    func processUserRequest(_ request: String, context: ConversationContext) async -> IntelligentResponse
    func planComplexTask(_ description: String) async -> TaskPlan
    func executeTaskWithCollaboration(_ plan: TaskPlan) async -> TaskResult
}
```

## Memory Management

### Conversation Context
- **Dynamic Context Window**: Automatically manages relevant conversation history
- **Topic Tracking**: Maintains awareness of conversation topics and transitions
- **Intent Sequence**: Understands multi-turn user intentions
- **Context Relevance**: Surfaces appropriate historical context for current queries

### Persistent Memory (Optional)
- **User Preferences**: Learns and remembers user communication style and preferences
- **Semantic Memory**: Stores important concepts and relationships
- **Learning Patterns**: Adapts behavior based on successful interactions
- **Privacy Controls**: User configurable data retention and deletion

### Enhanced Memory Capabilities - Vector RAG & YaRN Integration

#### Vector RAG Service Features (IMPLEMENTED)
- **Document Chunking**: Sophisticated semantic chunking for optimal retrieval
- **Embedding Generation**: 768-dimensional vectors for semantic similarity
- **Semantic Search**: Enhanced search across 164+ stored memories with relevance scoring
- **Cross-Conversation Memory**: Searches memories across all conversations with Vector RAG fallback
- **Document Processing**: Support for text documents, with extensibility for PDFs and other formats

#### YaRN Context Processor Features (IMPLEMENTED) 
- **Dynamic Context Windows**: Scales from 8K to 65K tokens based on content complexity
- **Attention Scaling**: Intelligent attention pattern management for long contexts
- **Compression Algorithms**: Context compression while preserving important information
- **Message Importance**: Analyzes message importance for intelligent retention/compression

### Memory UI Access (Session Intelligence Toolbar)

Users can inspect and search agent memory through the Session Intelligence toolbar, providing complete visibility into SAM's knowledge state across three distinct data layers:

#### Search Capabilities

**1. Stored Memory Search (Vector RAG)**
- Semantic search across stored memories in vector database
- Uses 768-dimensional embeddings for relevance matching
- Returns results with similarity scores (0-100%)
- Searches conversation-scoped or topic-scoped memories (when shared topics enabled)
- Threshold-based filtering (default: 15% similarity minimum)

**2. Active Context Search**
- Text matching in current conversation messages
- Searches through visible and recent messages in active context
- Real-time search without database queries
- Finds exact text matches with context preservation
- Shows message timestamps for temporal awareness

**3. Archived Context Search**
- Queries archived context chunks via ContextArchiveManager
- Searches summaries and key topics of archived chunks
- Returns chunk metadata (time range, message count, token count)
- Enables discovery of information from earlier in long conversations
- Supports both conversation-specific and topic-wide archive search

**4. Combined Multi-Source Search**
- Parallel search across all three sources (Stored + Active + Archive)
- User-controlled source toggles (enable/disable each independently)
- Unified result display with source badges (STORED/ACTIVE/ARCHIVE)
- Color-coded results for visual source identification
- Relevance-based result ordering across sources

#### Statistics Display

**Memory Status:**
- Total stored memories (count)
- Memory access count and average importance scores
- Memory span (temporal range from oldest to newest memory)
- Clear memories action button

**Intelligence Activity** (replaces Context Management):
- **Real-time Telemetry Tracking**:
  - Archive Recalls: Count of recall_history tool executions (agent fetching from archives)
  - Memory Searches: Count of RAG database queries (agent searching stored memories)
  - YaRN Compressions: Count of context compression events (when hitting API token limits)
- **Context Statistics**:
  - Active Tokens: Current conversation token count (estimated from messages)
  - Archived Chunks: Number of archived context chunks
  - Archived Tokens: Total tokens stored in archives
- **Archive Topics**: Top 5 topics from archived chunks (when available)
- **Compact 2x3 Grid Layout**: All statistics visible in space-efficient display

**Telemetry Persistence**:
- Stored in `conversation.settings.telemetry` (ConversationTelemetry struct)
- Automatically persisted with conversation JSON
- Backward compatible (defaults to zero for old conversations)
- Updated in real-time as agent performs operations

**User Benefits:**
- Complete visibility into agent intelligence activity
- Understanding of how often agent accesses different knowledge sources
- Awareness of context compression events (performance insights)
- Discovery of archived content through topic preview

#### Memory Configuration Through Conversation
```swift
// Enhanced memory configuration with Vector RAG and YaRN
enum MemoryConfiguration {
    case conversationOnly // Default: context isolated with YaRN compression
    case enhancedSemantic // Vector RAG semantic search enabled  
    case longContext // YaRN extended context (up to 65K tokens)
    case maximumCapability // Both Vector RAG and extended YaRN context
    case privacyMode // Maximum privacy, minimal retention
}

// Example user interactions:
// User: "Search my memory for anything about Vector RAG implementation"
// SAM: "Found 10 memories about Vector RAG, including detailed implementation discussions..."

// User: "Use extended context for this complex analysis" 
// SAM: "Enabled extended context mode with YaRN compression for up to 65K tokens..."
```

## Intelligence Capabilities

### Conversational Task Planning
- **Multi-Step Reasoning**: Breaks complex requests into manageable steps
- **Context-Aware Planning**: Uses conversation history to inform planning
- **User Collaboration**: Involves user in planning and execution decisions
- **Adaptive Execution**: Adjusts approach based on user feedback

### Contextual Understanding
- **Intent Recognition**: Understands user goals from natural language
- **Contextual Reasoning**: Uses conversation context to inform responses
- **Preference Adaptation**: Adapts communication style to user preferences
- **Situational Awareness**: Understands conversation flow and appropriate responses

### Learning and Adaptation
```swift
// Intelligent adaptation system
class UserAdaptationSystem {
    func learnFromInteraction(_ interaction: UserInteraction) async
    func adaptCommunicationStyle() async -> CommunicationStyle
    func personalizeResponses(based on: ConversationHistory) async
    func suggestImprovements() async -> [AdaptationSuggestion]
}

// Example adaptation:
// System learns user prefers: concise responses, code examples, step-by-step explanations
// Automatically adapts future responses to match these preferences
```

## Hardware Acceleration

### Apple Silicon Optimization
- **Neural Engine**: Accelerates semantic understanding and reasoning
- **Metal Performance Shaders**: Optimizes vector operations and memory processing
- **GPU Compute**: Parallel processing for complex analysis tasks
- **CPU Optimization**: Efficient multi-core utilization for concurrent operations

### Performance Management
```swift
// Hardware-aware processing
class HardwareOptimizer {
    func optimizeForDevice() async -> OptimizationProfile
    func accelerateMemoryOperations() async
    func balanceComputeLoad() async
    func monitorThermalState() async -> ThermalStatus
}
```

### Memory Efficiency
- **Lazy Loading**: Loads context and memory data on demand
- **Compression**: Efficient storage of conversation history
- **Caching**: Smart caching of frequently accessed data
- **Resource Monitoring**: Prevents memory leaks and excessive resource usage

## Privacy and Security

### Context Isolation
- **Conversation Boundaries**: Each conversation maintains separate context
- **Memory Isolation**: Long-term memory is optional and user-controlled
- **Data Encryption**: All persistent memory encrypted at rest
- **Access Controls**: User controls what data is retained and shared

### User Control
```swift
// User privacy controls through conversation
class PrivacyManager {
    func configureMemoryRetention(via conversation: String) async
    func forgetSpecificData(_ criteria: String) async
    func exportUserData() async -> UserDataExport
    func deleteAllPersonalData() async
}

// Example user interactions:
// "Forget everything about my work project" -> Deletes specific topic data
// "Only remember things for today's conversation" -> Configures session-only memory
// "What personal data do you have about me?" -> Shows transparency report
```

## Integration Points

### MCP Tool Integration
- **Context-Aware Tool Selection**: Chooses appropriate tools based on conversation context
- **Memory-Informed Parameters**: Uses memory to provide better tool parameters
- **Learning Tool Preferences**: Learns which tools user prefers for specific tasks
- **Tool Result Memory**: Remembers successful tool usage patterns

### API Compatibility
- **Stateless API**: Maintains compatibility with existing stateless API patterns
- **Context Injection**: Provides conversation context to API responses
- **Memory Queries**: API endpoints for memory management and queries
- **Privacy Compliance**: API respects user privacy configurations

## Implementation Phases

### Phase 1: Core Memory System
- Basic conversation context management
- Dynamic context window implementation
- Privacy-first architecture
- Context isolation between conversations

### Phase 2: Intelligence Engine
- Conversational task planning
- Multi-step reasoning capabilities
- User preference learning
- Adaptive communication style

### Phase 3: Advanced Features
- Long-term memory system (optional)
- Cross-conversation learning
- Advanced personalization
- Sophisticated context understanding

### Phase 4: Optimization
- Hardware acceleration implementation
- Performance optimization

## CURRENT IMPLEMENTATION STATUS (September 25, 2025)

### COMPLETED: Vector RAG Service Implementation

**Location**: `Sources/ConversationEngine/VectorRAGService.swift` (665 lines)

**Architecture Components**:
```swift
// Document processing and chunking
class DocumentChunker {
    func chunkDocument(_ document: RAGDocument) async throws -> [DocumentChunk]
    // Sophisticated semantic chunking with context preservation
}

// Embedding generation for semantic search
class EmbeddingGenerator {
    func generateEmbedding(for text: String) async throws -> [Double]
    // 768-dimensional embeddings with NaturalLanguage framework
}

// Core RAG service with full document lifecycle
class VectorRAGService {
    func ingestDocument(_ document: RAGDocument) async throws -> DocumentIngestionResult
    func semanticSearch(query: String, limit: Int, similarityThreshold: Double) async throws -> [SemanticSearchResult]
    func retrieveAugmentedContext(for query: String, conversationId: UUID) async throws -> RAGContext
}
```

**Integration Points**:
- **MemoryManagerAdapter**: Enhanced with Vector RAG semantic search fallback
- **ConversationManager**: Initializes and manages VectorRAGService lifecycle
- **Memory Search Tool**: MCP tool integration for conversational memory access

### COMPLETED: YaRN Context Processor Implementation

**Location**: `Sources/ConversationEngine/YaRNContextProcessor.swift` (609 lines)

**Context Management Features**:
```swift
// Dynamic context configuration
struct YaRNConfig {
    let baseContextLength: Int      // 8K-16K tokens
    let extendedContextLength: Int  // 32K-65K tokens  
    let scalingFactor: Double       // 4.0-8.0x scaling
    let attentionFactor: Double     // 0.05-0.1 attention scaling
    let compressionThreshold: Double // 0.8-0.85 compression ratio
}

// Context processing capabilities
class YaRNContextProcessor {
    func processConversationContext(messages: [Message], targetTokenCount: Int?) async throws -> ProcessedContext
    func applyYaRNCompression(_ messages: [Message], targetTokens: Int) async throws -> CompressedContext  
    func analyzeMessageImportance(_ messages: [Message]) async -> [MessageImportance]
    func generateAttentionPatterns() -> [AttentionPattern]
}
```

**Context Processing Algorithms**:
- **Importance Analysis**: Scores messages based on content, position, and user interaction patterns
- **Compression Strategies**: Multiple compression approaches (sliding window, importance-based, semantic clustering)
- **Attention Scaling**: Dynamic attention pattern management for extended contexts
- **Token Management**: Precise token counting and optimization for efficiency

### COMPLETED: Enhanced Memory Integration

**Cross-Conversation Search**: 164+ stored memories with semantic capabilities
**Enhanced MemoryManagerAdapter**: Vector RAG fallback for improved search results
**Document Content Support**: Memory system supports document content type for RAG integration
**Semantic Search Workflow**: Query → Vector RAG search → Traditional search fallback → Results

### OPERATIONAL STATUS

**Vector RAG Service**: "SUCCESS: VECTOR RAG - Enhanced search system operational" (confirmed in SAM logs)
**YaRN Context Processor**: "SUCCESS: YARN CONTEXT - Dynamic context management operational" (confirmed in SAM logs)  
**Memory Integration**: Enhanced semantic search working with MCP tools
**Total Implementation**: ~1,274 lines of sophisticated memory and context management code

This implementation achieves SAM 1.0 memory and context parity through modern Swift architecture with advanced semantic capabilities.
- Memory efficiency improvements
- Advanced privacy features

## User Experience Goals

### Seamless Intelligence
- Users experience intelligent, contextual responses without complexity
- System remembers conversation flow and user preferences naturally
- Complex reasoning happens transparently in the background
- Error handling maintains conversation flow with helpful explanations

### Privacy First
- Users control all memory and learning features through conversation
- Clear explanations of what data is retained and why
- Easy data deletion and privacy management
- Transparent operation with no hidden data collection

### Performance Excellence
- Fast, responsive interaction regardless of memory complexity
- Efficient resource usage on all supported Mac hardware
- Smooth conversation flow with minimal latency
- Graceful degradation under resource constraints

---

**This specification ensures that SAM delivers advanced memory and intelligence capabilities through an intuitive, user-friendly interface while maintaining the highest standards of privacy, performance, and technical excellence.**