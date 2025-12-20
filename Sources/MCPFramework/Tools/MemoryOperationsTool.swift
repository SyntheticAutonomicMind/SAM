// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import ConfigurationSystem

/// Memory Operations MCP Tool for semantic memory search and storage.
public class MemoryOperationsTool: ConsolidatedMCP, @unchecked Sendable {
    public let name = "memory_operations"

    /// Force serial execution to prevent duplicate memory stores when LLM calls this tool multiple times in one response
    public var requiresSerial: Bool { true }
    
    /// Tool result storage for large memory search results
    private let storage = ToolResultStorage()

    public let description = """
    Search and store conversation memory.

    OPERATIONS:
    • search_memory - Semantic search memories (query, similarity_threshold)
    • store_memory - Save to memory (content, content_type, tags)
    • list_collections - View memory statistics

    SIMILARITY_THRESHOLD: 0.0-1.0 (default 0.3)
    - Document/RAG: 0.15-0.25 (lower scores typical)
    - Conversation: 0.3-0.5
    - No results? Lower threshold: 0.3→0.2→0.15

    NOTE: For todo list management, use the 'todo_operations' tool instead.
    """

    public var supportedOperations: [String] {
        return [
            "search_memory",
            "store_memory",
            "list_collections"
        ]
    }

    public var parameters: [String: MCPToolParameter] {
        return [
            "operation": MCPToolParameter(
                type: .string,
                description: """
                    Operation to perform:
                    - search_memory: Query memories with natural language (includes similarity search)
                    - store_memory: Save new memory to database
                    - list_collections: View memory statistics

                    Note: For todo list management, use 'todo_operations' tool instead.
                    """,
                required: true,
                enumValues: [
                    "search_memory", "store_memory", "list_collections"
                ]
            ),

            /// Memory search parameters.
            "query": MCPToolParameter(
                type: .string,
                description: "Search query or content to store/find similar",
                required: false
            ),
            "content": MCPToolParameter(
                type: .string,
                description: "Content to store in memory (for store_memory)",
                required: false
            ),
            "content_type": MCPToolParameter(
                type: .string,
                description: "Type of content being stored",
                required: false,
                enumValues: ["interaction", "fact", "preference", "task", "document"]
            ),
            "context": MCPToolParameter(
                type: .string,
                description: "Additional context for the memory",
                required: false
            ),
            "tags": MCPToolParameter(
                type: .array,
                description: "Tags to associate with the memory",
                required: false,
                arrayElementType: .string
            ),
            "limit": MCPToolParameter(
                type: .integer,
                description: "Maximum number of results to return",
                required: false
            ),
            "similarity_threshold": MCPToolParameter(
                type: .string,
                description: """
                    Minimum similarity score (0.0-1.0). IMPORTANT GUIDELINES:
                    - For document/RAG searches: Use 0.15-0.25 (document embeddings produce lower scores)
                    - For conversation memory: Use 0.3-0.5 (conversation embeddings more precise)
                    - If no results found: Reduce threshold incrementally (0.3 → 0.2 → 0.15 → 0.0)
                    - Lower threshold = more results (may include less relevant)
                    - Higher threshold = fewer results (only highly relevant)
                    """,
                required: false
            )
        ]
    }

    private let logger = Logging.Logger(label: "com.sam.mcp.MemoryOperationsTool")
    private weak var memoryManager: MemoryManagerProtocol?

    /// Cache of recently stored memory content to prevent duplicate stores within a workflow session
    /// Key: SHA256 hash of content, Value: (memoryId, timestamp, contentPreview)
    /// Entries expire after 5 minutes to allow re-storing in new sessions
    nonisolated(unsafe) private static var recentlyStoredContent: [String: (memoryId: UUID, timestamp: Date, contentPreview: String)] = [:]
    private static let duplicateWindowSeconds: TimeInterval = 300  // 5 minutes

    /// Generate a content hash for duplicate detection
    private func contentHash(_ content: String) -> String {
        // Simple hash using the content's hashValue - sufficient for short-term duplicate detection
        return "\(content.hashValue)"
    }

    /// Check if content was recently stored (within duplicate window)
    /// Returns the existing memory ID if duplicate, nil otherwise
    private func checkForRecentDuplicate(_ content: String) -> (memoryId: UUID, contentPreview: String)? {
        let hash = contentHash(content)

        // Clean up expired entries
        let now = Date()
        MemoryOperationsTool.recentlyStoredContent = MemoryOperationsTool.recentlyStoredContent.filter {
            now.timeIntervalSince($0.value.timestamp) < MemoryOperationsTool.duplicateWindowSeconds
        }

        // Check for existing entry
        if let existing = MemoryOperationsTool.recentlyStoredContent[hash] {
            return (existing.memoryId, existing.contentPreview)
        }

        return nil
    }

    /// Record that content was stored (for duplicate detection)
    private func recordContentStored(_ content: String, memoryId: UUID) {
        let hash = contentHash(content)
        let preview = content.count > 50 ? String(content.prefix(47)) + "..." : content
        MemoryOperationsTool.recentlyStoredContent[hash] = (memoryId, Date(), preview)
    }

    public init() {
        logger.debug("MemoryOperationsTool initialized (memory search/store operations)")

        /// Register with ToolDisplayInfoRegistry for proper progress indicators.
        ToolDisplayInfoRegistry.shared.register("memory_operations", provider: MemoryOperationsTool.self)
    }

    /// Inject memory manager to avoid circular dependencies.
    public func setMemoryManager(_ memoryManager: MemoryManagerProtocol) {
        self.memoryManager = memoryManager
        logger.debug("MemoryManager injected into MemoryOperationsTool")
    }

    @MainActor
    public func routeOperation(
        _ operation: String,
        parameters: [String: Any],
        context: MCPExecutionContext
    ) async -> MCPToolResult {
        let startTime = Date()

        /// Validate parameters before routing.
        if let validationError = validateParameters(operation: operation, parameters: parameters) {
            return validationError
        }

        /// Route to appropriate operation handler.
        let result: MCPToolResult
        switch operation {
        /// Memory operations.
        case "search_memory":
            result = await handleSearchMemory(parameters: parameters, context: context)

        case "store_memory":
            result = await handleStoreMemory(parameters: parameters, context: context)

        case "list_collections":
            result = await handleListCollections(parameters: parameters, context: context)

        case "manage_todos":
            /// DEPRECATED: Redirect to todo_operations tool
            logger.warning("manage_todos is deprecated - use todo_operations tool instead")
            result = operationError(operation, message: """
                The 'manage_todos' operation has been moved to the 'todo_operations' tool.

                Please use: {"name": "todo_operations", "arguments": {"operation": "read|write|update", ...}}

                Example read: {"name": "todo_operations", "arguments": {"operation": "read"}}
                Example write: {"name": "todo_operations", "arguments": {"operation": "write", "todoList": [...]}}
                Example update: {"name": "todo_operations", "arguments": {"operation": "update", "todoUpdates": [...]}}
                """)

        default:
            logger.error("Unknown operation: \(operation)")
            result = operationError(operation, message: "Unknown operation")
        }

        let executionTime = Date().timeIntervalSince(startTime) * 1000
        logger.debug("\(name).\(operation) completed in \(String(format: "%.3f", executionTime))ms")

        return result
    }

    // MARK: - Parameter Validation

    private func validateParameters(operation: String, parameters: [String: Any]) -> MCPToolResult? {
        switch operation {
        case "search_memory":
            guard parameters["query"] is String else {
                return operationError(operation, message: """
                    Missing required parameter 'query'.

                    Usage: {"operation": "search_memory", "query": "your search query"}
                    Example: {"operation": "search_memory", "query": "previous conversation about Orlando"}
                    """)
            }

        case "store_memory":
            guard parameters["content"] is String else {
                return operationError(operation, message: """
                    Missing required parameter 'content'.

                    Usage: {"operation": "store_memory", "content": "information to remember"}
                    Example: {"operation": "store_memory", "content": "User prefers concise summaries"}
                    """)
            }

        default:
            break
        }

        return nil
    }

    // MARK: - Memory Search Operations

    @MainActor
    private func handleSearchMemory(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        guard let memoryManager = self.memoryManager else {
            return errorResult("Memory system not available")
        }

        guard let query = parameters["query"] as? String, !query.isEmpty else {
            return errorResult("'search_memory' operation requires 'query' parameter")
        }

        let limit = parameters["limit"] as? Int ?? 10

        /// Extract similarity_threshold parameter if provided.
        var similarityThreshold: Double?
        if let thresholdStr = parameters["similarity_threshold"] as? String,
           let threshold = Double(thresholdStr) {
            if threshold >= 0.0 && threshold <= 1.0 {
                similarityThreshold = threshold
            } else {
                logger.warning("similarity_threshold out of range (0.0-1.0): \(threshold), using default")
            }
        }

        /// Use effectiveScopeId for memory scoping
        /// When shared data enabled, this is the topic ID (shared across conversations)
        /// When shared data disabled, this is the conversation ID (isolated)
        let scopeId = context.effectiveScopeId
        logger.debug("Memory search: scopeId=\(scopeId?.uuidString ?? "nil"), query='\(query)'")

        do {
            let memories = try await memoryManager.searchMemories(
                query: query,
                limit: limit,
                similarityThreshold: similarityThreshold,
                conversationId: scopeId
            )

            if memories.isEmpty {
                return successResult("No memories found for query: '\(query)'")
            }

            var resultLines: [String] = []
            resultLines.append("SEARCH RESULTS (\(memories.count) memories found):")
            if let threshold = similarityThreshold {
                resultLines.append("Similarity threshold: \(String(format: "%.0f%%", threshold * 100))")
            }
            resultLines.append("")

            for (index, memory) in memories.enumerated() {
                resultLines.append("\(index + 1). [\(memory.contentType.rawValue)] \(memory.content)")
                if let relevance = memory.relevanceScore {
                    resultLines.append("   Relevance: \(String(format: "%.0f%%", relevance * 100))")
                }
                if !memory.tags.isEmpty {
                    resultLines.append("   Tags: \(memory.tags.joined(separator: ", "))")
                }
                resultLines.append("")
            }

            let fullResult = resultLines.joined(separator: "\n")
            
            /// Check if result is large enough to persist to disk
            let estimatedTokens = TokenEstimator.estimateTokens(fullResult)
            
            if estimatedTokens > ToolResultStorage.persistenceThreshold {
                /// Persist large result to disk to prevent context overflow
                guard let conversationId = context.conversationId,
                      let toolCallId = context.toolCallId else {
                    logger.warning("Memory search: Cannot persist large result (\(estimatedTokens) tokens) - missing conversation ID or tool call ID. Returning truncated.")
                    let truncated = TokenEstimator.truncate(fullResult, toTokenLimit: ToolResultStorage.previewTokenLimit)
                    logger.info("Memory search: Truncated to \(TokenEstimator.estimateTokens(truncated)) tokens")
                    return successResult(truncated)
                }
                
                do {
                    let metadata = try storage.persistResult(
                        content: fullResult,
                        toolCallId: toolCallId,
                        conversationId: conversationId
                    )
                    
                    logger.info("Memory search: Persisted result to disk (\(estimatedTokens) tokens -> \(metadata.filePath))")
                    
                    /// Return instructions to read the persisted result
                    let persistedMessage = """
                    [TOOL_RESULT_STORED]
                    
                    CRITICAL: Large memory search result (\(estimatedTokens) tokens, \(memories.count) memories) persisted to disk.
                    
                    YOU MUST use read_tool_result to access the full data BEFORE synthesizing your response.
                    DO NOT proceed without reading the full result.
                    
                    REQUIRED NEXT STEP:
                    read_tool_result(toolCallId: "\(toolCallId)", offset: 0, length: 8192)
                    
                    Continue reading with increasing offsets until hasMore=false.
                    Each read_tool_result call will indicate if more content remains.
                    
                    Metadata:
                    - Tool Call ID: \(toolCallId)
                    - Total Memories: \(memories.count)
                    - Total Tokens: \(estimatedTokens)
                    - Storage Path: \(metadata.filePath)
                    - Created: \(metadata.created)
                    """
                    
                    logger.debug("Memory search: Returning persist instructions for \(memories.count) results")
                    return successResult(persistedMessage)
                    
                } catch {
                    logger.error("Memory search: Failed to persist result: \(error), returning truncated")
                    let truncated = TokenEstimator.truncate(fullResult, toTokenLimit: ToolResultStorage.previewTokenLimit)
                    return successResult(truncated)
                }
            } else {
                /// Result is small enough to return directly
                logger.debug("Memory search completed: \(memories.count) results (\(estimatedTokens) tokens - inline)")
                return successResult(fullResult)
            }

        } catch {
            logger.error("Memory search failed: \(error)")
            return errorResult("Memory search failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func handleStoreMemory(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        guard let memoryManager = self.memoryManager else {
            return errorResult("Memory system not available")
        }

        guard let content = parameters["content"] as? String, !content.isEmpty else {
            return errorResult("'store_memory' operation requires 'content' parameter")
        }

        // DUPLICATE PREVENTION: Check if this content was recently stored
        // This prevents duplicate stores across auto-continue iterations
        if let existing = checkForRecentDuplicate(content) {
            logger.warning("Duplicate memory store prevented - content already stored as \(existing.memoryId.uuidString.prefix(8))")

            let successMessage = """
            MEMORY ALREADY EXISTS: \(existing.memoryId.uuidString)

            This exact content was already stored moments ago.
            Content preview: \(existing.contentPreview)

            No duplicate created. Move to the NEXT task - do NOT try to store this again.
            """

            return successResult(successMessage)
        }

        let contentTypeStr = parameters["content_type"] as? String ?? "interaction"
        let contentType = MemoryContentType(rawValue: contentTypeStr) ?? .interaction
        let contextStr = parameters["context"] as? String ?? ""
        let scopeId = context.effectiveScopeId?.uuidString
        let tags = parameters["tags"] as? [String] ?? []

        do {
            let memoryId = try await memoryManager.storeMemory(
                content: content,
                contentType: contentType,
                context: contextStr,
                conversationId: scopeId,
                tags: tags
            )

            logger.debug("Memory stored with ID: \(memoryId)")

            // Record this content to prevent duplicate stores in subsequent iterations
            recordContentStored(content, memoryId: memoryId)

            // Also record in MemoryReminderInjector so LLM gets reminded of stored memories
            let contentPreview = content.count > 100 ? String(content.prefix(97)) + "..." : content
            if let conversationId = context.conversationId {
                MemoryReminderInjector.shared.recordMemoryStored(
                    conversationId: conversationId,
                    memoryId: memoryId,
                    contentPreview: contentPreview
                )
            }

            let tagsDisplay = tags.isEmpty ? "none" : tags.joined(separator: ", ")

            let successMessage = """
            MEMORY STORED: \(memoryId.uuidString)

            Type: \(contentType.rawValue)
            Tags: \(tagsDisplay)
            Content: \(contentPreview)
            Length: \(content.count) characters

            **MEMORY STORAGE OPERATION COMPLETE**
            - Do not repeat this operation, move on to the next task
            """

            return successResult(successMessage)

        } catch {
            logger.error("Store memory failed: \(error)")
            return errorResult("Store memory failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func handleListCollections(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        guard let memoryManager = self.memoryManager else {
            return errorResult("Memory system not available")
        }

        do {
            let statistics = try await memoryManager.getMemoryStatistics()

            var resultLines: [String] = []
            resultLines.append("MEMORY COLLECTIONS:")
            resultLines.append("")
            resultLines.append("Total memories: \(statistics.totalMemories)")
            resultLines.append("")
            resultLines.append("By content type:")
            resultLines.append("- Interactions: \(statistics.interactionCount)")
            resultLines.append("- Facts: \(statistics.factCount)")
            resultLines.append("- Preferences: \(statistics.preferenceCount)")
            resultLines.append("- Tasks: \(statistics.taskCount)")
            resultLines.append("- Documents: \(statistics.documentCount)")
            resultLines.append("")
            resultLines.append("Recent memories: \(statistics.recentMemories)")
            resultLines.append("Average importance: \(String(format: "%.2f", statistics.averageImportance))")

            logger.debug("Memory collections listed: \(statistics.totalMemories) total memories")
            return successResult(resultLines.joined(separator: "\n"))

        } catch {
            logger.error("List collections failed: \(error)")
            return errorResult("List collections failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Protocol Conformance

extension MemoryOperationsTool: ToolDisplayInfoProvider {
    public static func extractDisplayInfo(from arguments: [String: Any]) -> String? {
        guard let operation = arguments["operation"] as? String else {
            return nil
        }

        /// Normalize operation names (handle aliases).
        let normalizedOp = operation.lowercased().replacingOccurrences(of: "_", with: "")

        switch normalizedOp {
        case "searchmemory":
            if let query = arguments["query"] as? String {
                return "Searching memory: \(query)"
            }
            return "Searching memory"

        case "storememory":
            if let content = arguments["content"] as? String {
                let preview = content.count > 50 ? String(content.prefix(47)) + "..." : content
                return "Storing memory: \(preview)"
            }
            return "Storing memory"

        case "listcollections":
            return "Listing memory collections"

        default:
            return nil
        }
    }

    public static func extractToolDetails(from arguments: [String: Any]) -> [String]? {
        guard let operation = arguments["operation"] as? String else {
            return nil
        }

        let normalizedOp = operation.lowercased().replacingOccurrences(of: "_", with: "")

        switch normalizedOp {
        case "searchmemory":
            var details: [String] = []
            if let query = arguments["query"] as? String {
                details.append("Query: \(query)")
            }
            if let threshold = arguments["similarity_threshold"] as? String {
                details.append("Threshold: \(threshold)")
            }
            return details.isEmpty ? nil : details

        case "storememory":
            var details: [String] = []
            if let content = arguments["content"] as? String {
                let preview = content.count > 60 ? String(content.prefix(57)) + "..." : content
                details.append("Content: \(preview)")
            }
            if let contentType = arguments["content_type"] as? String {
                details.append("Type: \(contentType)")
            }
            return details.isEmpty ? nil : details

        case "listcollections":
            return ["Operation: List all memory collections"]

        default:
            return nil
        }
    }
}
