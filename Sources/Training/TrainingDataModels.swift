import Foundation

/// Represents the data models for training data export
public struct TrainingDataModels {
    
    /// A single training example (user/assistant pair)
    public struct TrainingExample: Codable, Sendable {
        public let userMessage: String
        public let assistantMessage: String
        public let systemPrompt: String?
        public let metadata: [String: String]?
        public let includeReasoning: Bool
        public let includeToolCalls: Bool
        
        public init(
            userMessage: String,
            assistantMessage: String,
            systemPrompt: String? = nil,
            metadata: [String: String]? = nil,
            includeReasoning: Bool = false,
            includeToolCalls: Bool = false
        ) {
            self.userMessage = userMessage
            self.assistantMessage = assistantMessage
            self.systemPrompt = systemPrompt
            self.metadata = metadata
            self.includeReasoning = includeReasoning
            self.includeToolCalls = includeToolCalls
        }
    }
    
    /// JSONL format for training (one JSON object per line)
    public struct JSONLEntry: Codable, Sendable {
        public let text: String
        public let metadata: [String: String]?
        
        public init(text: String, metadata: [String: String]? = nil) {
            self.text = text
            self.metadata = metadata
        }
    }
    
    /// Configuration options for training data export
    public struct ExportOptions: Sendable {
        public let stripPII: Bool
        public let includeSystemPrompts: Bool
        public let includeToolCalls: Bool
        public let includeThinkTags: Bool
        public let selectedPIIEntities: Set<PIIDetector.PIIEntity>
        public let template: ChatTemplate
        public let modelId: String?  // For dynamic template from installed model
        public let customTemplate: String?  // Jinja2 template string from model
        public let outputFormat: OutputFormat
        
        public enum OutputFormat: String, CaseIterable, Sendable {
            case jsonl = "JSONL"
            case json = "JSON"
        }
        
        public init(
            stripPII: Bool = false,
            includeSystemPrompts: Bool = false,
            includeToolCalls: Bool = true,
            includeThinkTags: Bool = true,
            selectedPIIEntities: Set<PIIDetector.PIIEntity> = [.personalName, .organizationName],
            template: ChatTemplate = .llama3,
            modelId: String? = nil,
            customTemplate: String? = nil,
            outputFormat: OutputFormat = .jsonl
        ) {
            self.stripPII = stripPII
            self.includeSystemPrompts = includeSystemPrompts
            self.includeToolCalls = includeToolCalls
            self.includeThinkTags = includeThinkTags
            self.selectedPIIEntities = selectedPIIEntities
            self.template = template
            self.modelId = modelId
            self.customTemplate = customTemplate
            self.outputFormat = outputFormat
        }
        
        public static let `default` = ExportOptions()
    }
    
    /// Statistics about exported training data
    public struct ExportStatistics: Sendable {
        public let totalExamples: Int
        public let totalTokensEstimate: Int
        public let piiRedactions: [PIIDetector.PIIEntity: Int]
        public let examplesWithToolCalls: Int
        public let examplesWithReasoning: Int
        public let averageMessageLength: Int
        public let outputFileSize: Int64
        
        public init(
            totalExamples: Int,
            totalTokensEstimate: Int,
            piiRedactions: [PIIDetector.PIIEntity: Int] = [:],
            examplesWithToolCalls: Int = 0,
            examplesWithReasoning: Int = 0,
            averageMessageLength: Int = 0,
            outputFileSize: Int64 = 0
        ) {
            self.totalExamples = totalExamples
            self.totalTokensEstimate = totalTokensEstimate
            self.piiRedactions = piiRedactions
            self.examplesWithToolCalls = examplesWithToolCalls
            self.examplesWithReasoning = examplesWithReasoning
            self.averageMessageLength = averageMessageLength
            self.outputFileSize = outputFileSize
        }
        
        /// Rough token estimate (words * 1.3)
        public static func estimateTokens(for text: String) -> Int {
            let words = text.split(separator: " ").count
            return Int(Double(words) * 1.3)
        }
    }
    
    /// Result of a training data export operation
    public struct ExportResult: Sendable {
        public let outputURL: URL
        public let statistics: ExportStatistics
        public let template: ChatTemplate
        public let options: ExportOptions
        
        public init(
            outputURL: URL,
            statistics: ExportStatistics,
            template: ChatTemplate,
            options: ExportOptions
        ) {
            self.outputURL = outputURL
            self.statistics = statistics
            self.template = template
            self.options = options
        }
    }
    
    /// Configuration options for document-to-training export
    public struct DocumentExportOptions: Sendable {
        public let chunkingStrategy: ChunkingStrategy
        public let maxChunkTokens: Int
        public let overlapTokens: Int
        public let stripPII: Bool
        public let selectedPIIEntities: Set<PIIDetector.PIIEntity>
        public let template: ChatTemplate
        public let customTemplate: String?
        
        public enum ChunkingStrategy: String, CaseIterable, Sendable {
            case semantic = "Semantic (Paragraphs)"
            case fixedSize = "Fixed Size"
            case pageAware = "Page Aware (PDFs)"
        }
        
        public init(
            chunkingStrategy: ChunkingStrategy = .semantic,
            maxChunkTokens: Int = 512,
            overlapTokens: Int = 50,
            stripPII: Bool = false,
            selectedPIIEntities: Set<PIIDetector.PIIEntity> = [.personalName, .organizationName],
            template: ChatTemplate = .llama3,
            customTemplate: String? = nil
        ) {
            self.chunkingStrategy = chunkingStrategy
            self.maxChunkTokens = maxChunkTokens
            self.overlapTokens = overlapTokens
            self.stripPII = stripPII
            self.selectedPIIEntities = selectedPIIEntities
            self.template = template
            self.customTemplate = customTemplate
        }
        
        public static let `default` = DocumentExportOptions()
    }
    
    /// Represents a text chunk from a document
    public struct DocumentChunk: Sendable {
        public let text: String
        public let sourceFile: String
        public let chunkIndex: Int
        public let pageNumber: Int?
        public let metadata: [String: String]
        
        public init(
            text: String,
            sourceFile: String,
            chunkIndex: Int,
            pageNumber: Int? = nil,
            metadata: [String: String] = [:]
        ) {
            self.text = text
            self.sourceFile = sourceFile
            self.chunkIndex = chunkIndex
            self.pageNumber = pageNumber
            self.metadata = metadata
        }
    }
    
    /// Snapshot of a conversation memory (avoids circular dependency with ConversationEngine)
    /// Caller must convert ConversationMemory → ConversationMemorySnapshot before calling export
    public struct ConversationMemorySnapshot: Sendable {
        public let id: UUID
        public let content: String
        public let contentType: String
        public let importance: Double
        public let tags: [String]
        
        public init(
            id: UUID,
            content: String,
            contentType: String,
            importance: Double,
            tags: [String]
        ) {
            self.id = id
            self.content = content
            self.contentType = contentType
            self.importance = importance
            self.tags = tags
        }
    }
}
