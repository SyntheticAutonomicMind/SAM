import Foundation
import ConfigurationSystem
import Logging

/// Core engine for exporting conversations and other data as LLM training datasets
/// Coordinates PII detection, chat template formatting, and JSONL file generation
public actor TrainingDataExporter {
    private let piiDetector: PIIDetector
    private let templateEngine: ChatTemplateEngine
    private let chunker: DocumentChunker
    private let logger: Logger
    
    public init() {
        self.piiDetector = PIIDetector()
        self.templateEngine = ChatTemplateEngine()
        self.chunker = DocumentChunker()
        self.logger = Logger(label: "com.sam.training.exporter")
    }
    
    // MARK: - Public Export Methods
    
    /// Export a conversation as training data in JSONL format
    /// - Parameters:
    ///   - messages: Array of conversation messages
    ///   - outputURL: Where to write the JSONL file
    ///   - options: Export configuration (PII, templates, etc.)
    /// - Returns: Export result with statistics and metadata
    public func exportConversation(
        messages: [EnhancedMessage],
        outputURL: URL,
        options: TrainingDataModels.ExportOptions
    ) async throws -> TrainingDataModels.ExportResult {
        logger.info("Starting conversation export", metadata: [
            "messageCount": "\(messages.count)",
            "template": "\(options.template.rawValue)",
            "stripPII": "\(options.stripPII)"
        ])
        
        // Extract user/assistant pairs from conversation
        let trainingPairs = extractTrainingPairs(from: messages, options: options)
        logger.debug("Extracted training pairs", metadata: ["count": "\(trainingPairs.count)"])
        
        // Apply PII redaction if enabled
        var processedPairs = trainingPairs
        var piiRedactions: [PIIDetector.PIIEntity: Int] = [:]
        
        if options.stripPII {
            (processedPairs, piiRedactions) = await applyPIIRedaction(
                to: trainingPairs,
                entities: options.selectedPIIEntities
            )
            logger.info("PII redaction complete", metadata: [
                "totalRedactions": "\(piiRedactions.values.reduce(0, +))"
            ])
        }
        
        // Format and write JSONL
        let statistics = try await writeJSONL(
            pairs: processedPairs,
            to: outputURL,
            template: options.template,
            systemPrompt: options.includeSystemPrompts ? extractSystemPrompt(from: messages) : nil,
            piiRedactions: piiRedactions,
            options: options
        )
        
        logger.info("Export complete", metadata: [
            "outputFile": "\(outputURL.path)",
            "totalExamples": "\(statistics.totalExamples)",
            "estimatedTokens": "\(statistics.totalTokensEstimate)"
        ])
        
        return TrainingDataModels.ExportResult(
            outputURL: outputURL,
            statistics: statistics,
            template: options.template,
            options: options
        )
    }
    
    /// Export documents as training data in JSONL format
    /// Documents are chunked and formatted as text continuation examples
    /// - Parameters:
    ///   - documents: Array of imported documents with content and metadata
    ///   - outputURL: Where to write the JSONL file
    ///   - options: Export configuration (chunking, PII, templates, etc.)
    ///   - pages: Optional page content for page-aware chunking
    /// - Returns: Export result with statistics and metadata
    public func exportDocuments(
        documents: [ImportedDocument],
        outputURL: URL,
        options: TrainingDataModels.DocumentExportOptions,
        pages: [String: [PageContent]]? = nil
    ) async throws -> TrainingDataModels.ExportResult {
        logger.info("Starting document export", metadata: [
            "documentCount": "\(documents.count)",
            "template": "\(options.template.rawValue)",
            "chunkingStrategy": "\(options.chunkingStrategy.rawValue)"
        ])
        
        // Chunk all documents
        var allChunks: [TrainingDataModels.DocumentChunk] = []
        for document in documents {
            let documentPages = pages?[document.filename]
            let chunks = await chunker.chunkDocument(
                text: document.content,
                sourceFile: document.filename,
                options: options,
                pages: documentPages
            )
            allChunks.append(contentsOf: chunks)
        }
        
        logger.debug("Documents chunked", metadata: [
            "totalChunks": "\(allChunks.count)"
        ])
        
        // Apply PII redaction if enabled
        var processedChunks = allChunks
        var piiRedactions: [PIIDetector.PIIEntity: Int] = [:]
        
        if options.stripPII {
            (processedChunks, piiRedactions) = await applyPIIRedactionToChunks(
                chunks: allChunks,
                entities: options.selectedPIIEntities
            )
            logger.info("PII redaction complete", metadata: [
                "totalRedactions": "\(piiRedactions.values.reduce(0, +))"
            ])
        }
        
        // Format and write JSONL
        let statistics = try await writeDocumentJSONL(
            chunks: processedChunks,
            to: outputURL,
            template: options.template,
            customTemplate: options.customTemplate,
            piiRedactions: piiRedactions
        )
        
        logger.info("Document export complete", metadata: [
            "outputFile": "\(outputURL.path)",
            "totalExamples": "\(statistics.totalExamples)",
            "estimatedTokens": "\(statistics.totalTokensEstimate)"
        ])
        
        // Create ExportOptions for result (map DocumentExportOptions to ExportOptions)
        let exportOptions = TrainingDataModels.ExportOptions(
            stripPII: options.stripPII,
            includeSystemPrompts: false,
            includeToolCalls: false,
            includeThinkTags: false,
            selectedPIIEntities: options.selectedPIIEntities,
            template: options.template,
            modelId: nil,
            customTemplate: options.customTemplate,
            outputFormat: .jsonl
        )
        
        return TrainingDataModels.ExportResult(
            outputURL: outputURL,
            statistics: statistics,
            template: options.template,
            options: exportOptions
        )
    }
    
    /// Export conversation memory (imported documents) as training data
    /// Retrieves document chunks from conversation memory and exports them directly
    /// - Parameters:
    ///   - memories: Array of conversation memories (document chunks)
    ///   - outputURL: Where to write the JSONL file
    ///   - options: Export configuration (PII, templates, etc.)
    /// - Returns: Export result with statistics and metadata
    public func exportConversationMemory(
        memories: [TrainingDataModels.ConversationMemorySnapshot],
        outputURL: URL,
        options: TrainingDataModels.DocumentExportOptions
    ) async throws -> TrainingDataModels.ExportResult {
        logger.info("Starting conversation memory export", metadata: [
            "memoryCount": "\(memories.count)",
            "template": "\(options.template.rawValue)"
        ])
        
        // Filter for document memories (tagged with "rag" or "document")
        let documentMemories = memories.filter { memory in
            memory.tags.contains("rag") || memory.tags.contains("document")
        }
        
        logger.debug("Filtered document memories", metadata: [
            "totalMemories": "\(memories.count)",
            "documentMemories": "\(documentMemories.count)"
        ])
        
        guard !documentMemories.isEmpty else {
            throw TrainingExportError.noConversationData
        }
        
        // Convert memories to document chunks
        var chunks: [TrainingDataModels.DocumentChunk] = []
        for (index, memory) in documentMemories.enumerated() {
            // Extract source file from tags if available
            let sourceFile = memory.tags.first(where: { !["rag", "document", "text", "code"].contains($0) }) ?? "conversation_memory"
            
            chunks.append(TrainingDataModels.DocumentChunk(
                text: memory.content,
                sourceFile: sourceFile,
                chunkIndex: index,
                metadata: [
                    "memoryId": memory.id.uuidString,
                    "contentType": memory.contentType,
                    "importance": "\(memory.importance)",
                    "tags": memory.tags.joined(separator: ",")
                ]
            ))
        }
        
        // Apply PII redaction if enabled
        var processedChunks = chunks
        var piiRedactions: [PIIDetector.PIIEntity: Int] = [:]
        
        if options.stripPII {
            (processedChunks, piiRedactions) = await applyPIIRedactionToChunks(
                chunks: chunks,
                entities: options.selectedPIIEntities
            )
            logger.info("PII redaction complete", metadata: [
                "totalRedactions": "\(piiRedactions.values.reduce(0, +))"
            ])
        }
        
        // Format and write JSONL
        let statistics = try await writeDocumentJSONL(
            chunks: processedChunks,
            to: outputURL,
            template: options.template,
            customTemplate: options.customTemplate,
            piiRedactions: piiRedactions
        )
        
        logger.info("Conversation memory export complete", metadata: [
            "outputFile": "\(outputURL.path)",
            "totalExamples": "\(statistics.totalExamples)",
            "estimatedTokens": "\(statistics.totalTokensEstimate)"
        ])
        
        // Create ExportOptions for result
        let exportOptions = TrainingDataModels.ExportOptions(
            stripPII: options.stripPII,
            includeSystemPrompts: false,
            includeToolCalls: false,
            includeThinkTags: false,
            selectedPIIEntities: options.selectedPIIEntities,
            template: options.template,
            modelId: nil,
            customTemplate: options.customTemplate,
            outputFormat: .jsonl
        )
        
        return TrainingDataModels.ExportResult(
            outputURL: outputURL,
            statistics: statistics,
            template: options.template,
            options: exportOptions
        )
    }
    
    // MARK: - Private Helper Methods
    
    /// Extract user/assistant message pairs suitable for training
    /// Filters out tool messages, system messages, and incomplete pairs
    private func extractTrainingPairs(
        from messages: [EnhancedMessage],
        options: TrainingDataModels.ExportOptions
    ) -> [(user: String, assistant: String, hasToolCalls: Bool, hasReasoning: Bool)] {
        var pairs: [(user: String, assistant: String, hasToolCalls: Bool, hasReasoning: Bool)] = []
        var pendingUserMessage: (content: String, index: Int)?
        
        for (index, message) in messages.enumerated() {
            // Skip system-generated messages
            if message.isSystemGenerated {
                continue
            }
            
            // Handle user messages
            if message.isFromUser {
                pendingUserMessage = (message.content, index)
                continue
            }
            
            // Handle assistant messages
            if !message.isFromUser && !message.isToolMessage {
                guard let userMsg = pendingUserMessage else {
                    continue // No user message to pair with
                }
                
                var assistantContent = message.content
                let hasReasoning = message.reasoningContent != nil
                let hasToolCalls = message.toolCalls != nil && !(message.toolCalls?.isEmpty ?? true)
                
                // Include reasoning/thinking content if enabled
                if options.includeThinkTags, let reasoning = message.reasoningContent {
                    assistantContent = "<think>\n\(reasoning)\n</think>\n\n\(assistantContent)"
                }
                
                // Include tool calls if enabled
                if options.includeToolCalls, let toolCalls = message.toolCalls {
                    let toolCallsText = formatToolCalls(toolCalls)
                    assistantContent = "\(assistantContent)\n\n\(toolCallsText)"
                }
                
                pairs.append((
                    user: userMsg.content,
                    assistant: assistantContent,
                    hasToolCalls: hasToolCalls,
                    hasReasoning: hasReasoning
                ))
                
                pendingUserMessage = nil
            }
        }
        
        return pairs
    }
    
    /// Format tool calls for training data
    private func formatToolCalls(_ toolCalls: [SimpleToolCall]) -> String {
        var result = "<tool_calls>"
        for call in toolCalls {
            result += "\n<tool_call id=\"\(call.id)\" name=\"\(call.function.name)\">"
            result += "\n\(call.function.arguments)"
            result += "\n</tool_call>"
        }
        result += "\n</tool_calls>"
        return result
    }
    
    /// Extract system prompt from messages if present
    private func extractSystemPrompt(from messages: [EnhancedMessage]) -> String? {
        // Look for first systemStatus-type message
        for message in messages {
            if message.type == .systemStatus {
                return message.content
            }
        }
        return nil
    }
    
    /// Apply PII redaction to all message pairs
    private func applyPIIRedaction(
        to pairs: [(user: String, assistant: String, hasToolCalls: Bool, hasReasoning: Bool)],
        entities: Set<PIIDetector.PIIEntity>
    ) async -> (
        pairs: [(user: String, assistant: String, hasToolCalls: Bool, hasReasoning: Bool)],
        redactions: [PIIDetector.PIIEntity: Int]
    ) {
        var processedPairs: [(user: String, assistant: String, hasToolCalls: Bool, hasReasoning: Bool)] = []
        var totalRedactions: [PIIDetector.PIIEntity: Int] = [:]
        
        for pair in pairs {
            // Detect and strip PII from user message
            let userPII = await piiDetector.analyzePII(in: pair.user)
            let cleanUser = await piiDetector.stripPII(from: pair.user)
            
            // Detect and strip PII from assistant message
            let assistantPII = await piiDetector.analyzePII(in: pair.assistant)
            let cleanAssistant = await piiDetector.stripPII(from: pair.assistant)
            
            // Merge redaction counts
            for (entity, count) in userPII {
                if entities.contains(entity) {
                    totalRedactions[entity, default: 0] += count
                }
            }
            for (entity, count) in assistantPII {
                if entities.contains(entity) {
                    totalRedactions[entity, default: 0] += count
                }
            }
            
            processedPairs.append((
                user: cleanUser,
                assistant: cleanAssistant,
                hasToolCalls: pair.hasToolCalls,
                hasReasoning: pair.hasReasoning
            ))
        }
        
        return (processedPairs, totalRedactions)
    }
    
    /// Format pairs with chat template and write to JSONL file
    private func writeJSONL(
        pairs: [(user: String, assistant: String, hasToolCalls: Bool, hasReasoning: Bool)],
        to outputURL: URL,
        template: ChatTemplate,
        systemPrompt: String?,
        piiRedactions: [PIIDetector.PIIEntity: Int],
        options: TrainingDataModels.ExportOptions
    ) async throws -> TrainingDataModels.ExportStatistics {
        // Create output directory if needed
        let outputDirectory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        
        var jsonlLines: [String] = []
        var totalTokens = 0
        var totalMessageLength = 0
        var examplesWithToolCalls = 0
        var examplesWithReasoning = 0
        
        for pair in pairs {
            // Format with template (use custom template if provided)
            let formatted: String
            if let customTemplate = options.customTemplate {
                // Use dynamic template from installed model
                formatted = await templateEngine.formatWithTemplate(
                    userMessage: pair.user,
                    assistantMessage: pair.assistant,
                    templateString: customTemplate,
                    systemPrompt: systemPrompt
                )
            } else {
                // Fall back to static template
                formatted = await templateEngine.format(
                    userMessage: pair.user,
                    assistantMessage: pair.assistant,
                    template: template,
                    systemPrompt: systemPrompt
                )
            }
            
            // Create JSONL entry
            let entry = TrainingDataModels.JSONLEntry(
                text: formatted,
                metadata: [
                    "hasToolCalls": "\(pair.hasToolCalls)",
                    "hasReasoning": "\(pair.hasReasoning)"
                ]
            )
            
            // Encode to JSON (one line)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [] // Compact, no newlines
            let jsonData = try encoder.encode(entry)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                throw TrainingExportError.encodingFailed
            }
            
            jsonlLines.append(jsonString)
            
            // Track statistics
            totalTokens += TrainingDataModels.ExportStatistics.estimateTokens(for: formatted)
            totalMessageLength += formatted.count
            if pair.hasToolCalls { examplesWithToolCalls += 1 }
            if pair.hasReasoning { examplesWithReasoning += 1 }
        }
        
        // Write all lines to file
        let jsonlContent = jsonlLines.joined(separator: "\n")
        try jsonlContent.write(to: outputURL, atomically: true, encoding: .utf8)
        
        // Get file size
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        
        let averageLength = pairs.isEmpty ? 0 : totalMessageLength / pairs.count
        
        return TrainingDataModels.ExportStatistics(
            totalExamples: pairs.count,
            totalTokensEstimate: totalTokens,
            piiRedactions: piiRedactions,
            examplesWithToolCalls: examplesWithToolCalls,
            examplesWithReasoning: examplesWithReasoning,
            averageMessageLength: averageLength,
            outputFileSize: fileSize
        )
    }
    
    /// Apply PII redaction to document chunks
    private func applyPIIRedactionToChunks(
        chunks: [TrainingDataModels.DocumentChunk],
        entities: Set<PIIDetector.PIIEntity>
    ) async -> (
        chunks: [TrainingDataModels.DocumentChunk],
        redactions: [PIIDetector.PIIEntity: Int]
    ) {
        var processedChunks: [TrainingDataModels.DocumentChunk] = []
        var totalRedactions: [PIIDetector.PIIEntity: Int] = [:]
        
        for chunk in chunks {
            // Detect and strip PII from chunk text
            let pii = await piiDetector.analyzePII(in: chunk.text)
            let cleanText = await piiDetector.stripPII(from: chunk.text)
            
            // Merge redaction counts
            for (entity, count) in pii {
                if entities.contains(entity) {
                    totalRedactions[entity, default: 0] += count
                }
            }
            
            // Create cleaned chunk
            processedChunks.append(TrainingDataModels.DocumentChunk(
                text: cleanText,
                sourceFile: chunk.sourceFile,
                chunkIndex: chunk.chunkIndex,
                pageNumber: chunk.pageNumber,
                metadata: chunk.metadata
            ))
        }
        
        return (processedChunks, totalRedactions)
    }
    
    /// Format document chunks and write to JSONL file
    private func writeDocumentJSONL(
        chunks: [TrainingDataModels.DocumentChunk],
        to outputURL: URL,
        template: ChatTemplate,
        customTemplate: String?,
        piiRedactions: [PIIDetector.PIIEntity: Int]
    ) async throws -> TrainingDataModels.ExportStatistics {
        // Create output directory if needed
        let outputDirectory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        
        var jsonlLines: [String] = []
        var totalTokens = 0
        var totalMessageLength = 0
        
        for chunk in chunks {
            // Format chunk as text continuation (no user/assistant structure)
            // Just wrap in template markers for consistency
            let formatted: String
            if let customTemplate = customTemplate {
                formatted = await templateEngine.formatWithTemplate(
                    userMessage: "",
                    assistantMessage: chunk.text,
                    templateString: customTemplate,
                    systemPrompt: nil
                )
            } else {
                // For text continuation, we just want the text with minimal formatting
                // Use simple format without user/assistant markers
                formatted = chunk.text
            }
            
            // Create JSONL entry with chunk metadata
            var metadata = chunk.metadata
            metadata["sourceFile"] = chunk.sourceFile
            metadata["chunkIndex"] = "\(chunk.chunkIndex)"
            if let pageNumber = chunk.pageNumber {
                metadata["pageNumber"] = "\(pageNumber)"
            }
            
            let entry = TrainingDataModels.JSONLEntry(
                text: formatted,
                metadata: metadata
            )
            
            // Encode to JSON (one line)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [] // Compact, no newlines
            let jsonData = try encoder.encode(entry)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                throw TrainingExportError.encodingFailed
            }
            
            jsonlLines.append(jsonString)
            
            // Track statistics
            totalTokens += TrainingDataModels.ExportStatistics.estimateTokens(for: formatted)
            totalMessageLength += formatted.count
        }
        
        // Write all lines to file
        let jsonlContent = jsonlLines.joined(separator: "\n")
        try jsonlContent.write(to: outputURL, atomically: true, encoding: .utf8)
        
        // Get file size
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        
        let averageLength = chunks.isEmpty ? 0 : totalMessageLength / chunks.count
        
        return TrainingDataModels.ExportStatistics(
            totalExamples: chunks.count,
            totalTokensEstimate: totalTokens,
            piiRedactions: piiRedactions,
            examplesWithToolCalls: 0,
            examplesWithReasoning: 0,
            averageMessageLength: averageLength,
            outputFileSize: fileSize
        )
    }
}

// MARK: - Imported Document (from DocumentImportSystem)

/// Represents an imported document with processing metadata
/// This matches the structure from DocumentImportSystem
public struct ImportedDocument: Sendable {
    public let id: UUID
    public let filename: String
    public let content: String
    public let metadata: [String: String]
    
    public init(id: UUID, filename: String, content: String, metadata: [String: String] = [:]) {
        self.id = id
        self.filename = filename
        self.content = content
        self.metadata = metadata
    }
}

// MARK: - Errors

public enum TrainingExportError: Error, LocalizedError {
    case encodingFailed
    case invalidOutputPath
    case noConversationData
    
    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode training data to JSON"
        case .invalidOutputPath:
            return "Invalid output file path"
        case .noConversationData:
            return "No conversation data to export"
        }
    }
}
