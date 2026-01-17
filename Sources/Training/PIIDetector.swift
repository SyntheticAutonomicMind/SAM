import Foundation
import NaturalLanguage
import Logging

/// Detects and removes Personally Identifiable Information (PII) from text
/// Uses Apple's NaturalLanguage framework for entity recognition
public actor PIIDetector {
    private let logger = Logger(label: "com.sam.training.piidetector")
    
    /// Types of PII entities that can be detected and redacted
    public enum PIIEntity: String, CaseIterable, Sendable {
        case personalName = "Personal Name"
        case organizationName = "Organization Name"
        case placeName = "Place Name"
        case emailAddress = "Email Address"
        case phoneNumber = "Phone Number"
        case creditCardNumber = "Credit Card Number"
        case socialSecurityNumber = "Social Security Number"
        case ipAddress = "IP Address"
        case url = "URL"
        
        var nlTag: NLTag? {
            switch self {
            case .personalName: return .personalName
            case .organizationName: return .organizationName
            case .placeName: return .placeName
            default: return nil  // Pattern-based detection
            }
        }
        
        /// Regex pattern for pattern-based PII detection
        var pattern: String? {
            switch self {
            case .emailAddress:
                return #"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#
            case .phoneNumber:
                return #"\b(\+\d{1,3}[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b"#
            case .creditCardNumber:
                // Matches common credit card formats (with or without spaces/dashes)
                return #"\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b"#
            case .socialSecurityNumber:
                return #"\b\d{3}[-\s]?\d{2}[-\s]?\d{4}\b"#
            case .ipAddress:
                return #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#
            case .url:
                return #"https?://[^\s]+"#
            default:
                return nil
            }
        }
    }
    
    /// Configuration for PII detection
    public struct Configuration: Sendable {
        public let entitiesToRedact: Set<PIIEntity>
        
        public init(
            entitiesToRedact: Set<PIIEntity> = [.personalName, .organizationName]
        ) {
            self.entitiesToRedact = entitiesToRedact
        }
        
        public static let `default` = Configuration()
        
        /// Get redaction placeholder for an entity
        public func placeholder(for entity: PIIEntity) -> String {
            "[REDACTED_\(entity.rawValue.uppercased().replacingOccurrences(of: " ", with: "_"))]"
        }
    }
    
    private let configuration: Configuration
    
    public init(configuration: Configuration = .default) {
        self.configuration = configuration
        logger.info("PIIDetector initialized", metadata: [
            "entities": "\(configuration.entitiesToRedact.map(\.rawValue))"
        ])
    }
    
    /// Detects PII entities in the given text
    /// - Parameter text: Text to analyze
    /// - Returns: Array of detected entities with their ranges and types
    public func detectPII(in text: String) -> [(range: Range<String.Index>, entity: PIIEntity)] {
        var detectedEntities: [(Range<String.Index>, PIIEntity)] = []
        
        // 1. NaturalLanguage-based detection (names, places, orgs)
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation]
        
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: options
        ) { tag, range in
            guard let tag = tag else { return true }
            
            // Map NLTag to our PIIEntity
            for entity in PIIEntity.allCases {
                if let nlTag = entity.nlTag, 
                   tag == nlTag && 
                   configuration.entitiesToRedact.contains(entity) {
                    detectedEntities.append((range, entity))
                    break
                }
            }
            
            return true
        }
        
        // 2. Pattern-based detection (emails, phones, credit cards, etc.)
        for entity in PIIEntity.allCases {
            guard configuration.entitiesToRedact.contains(entity),
                  let pattern = entity.pattern,
                  let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                continue
            }
            
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = regex.matches(in: text, options: [], range: nsRange)
            
            for match in matches {
                if let range = Range(match.range, in: text) {
                    detectedEntities.append((range, entity))
                }
            }
        }
        
        // Sort by range to maintain order
        let sortedEntities = detectedEntities.sorted { (a: (range: Range<String.Index>, entity: PIIEntity), b: (range: Range<String.Index>, entity: PIIEntity)) -> Bool in
            a.range.lowerBound < b.range.lowerBound
        }
        
        logger.debug("Detected PII entities", metadata: ["count": "\(sortedEntities.count)"])
        return sortedEntities
    }
    
    /// Strips PII from text by replacing detected entities with placeholders
    /// - Parameter text: Text to sanitize
    /// - Returns: Sanitized text with PII replaced
    public func stripPII(from text: String) -> String {
        let entities = detectPII(in: text)
        
        guard !entities.isEmpty else {
            logger.debug("No PII detected, returning original text")
            return text
        }
        
        // Sort entities by range (reverse order) to avoid index invalidation
        let sortedEntities = entities.sorted { $0.range.lowerBound > $1.range.lowerBound }
        
        var sanitized = text
        var redactionCount: [PIIEntity: Int] = [:]
        
        for (range, entity) in sortedEntities {
            let placeholder = configuration.placeholder(for: entity)
            sanitized.replaceSubrange(range, with: placeholder)
            redactionCount[entity, default: 0] += 1
        }
        
        logger.info("Stripped PII from text", metadata: [
            "redactions": "\(redactionCount.map { "\($0.key.rawValue): \($0.value)" }.joined(separator: ", "))"
        ])
        
        return sanitized
    }
    
    /// Analyzes text and returns statistics about detected PII
    /// - Parameter text: Text to analyze
    /// - Returns: Dictionary mapping entity types to count of occurrences
    public func analyzePII(in text: String) -> [PIIEntity: Int] {
        let entities = detectPII(in: text)
        var statistics: [PIIEntity: Int] = [:]
        
        for (_, entity) in entities {
            statistics[entity, default: 0] += 1
        }
        
        return statistics
    }
}
