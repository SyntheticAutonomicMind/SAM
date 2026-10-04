// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

/// LongTermMemory.swift - Structured long-term memory for SAM
/// Ported from CLIO's Memory::LongTerm module.
///
/// LTM stores structured knowledge that persists across conversations:
/// discoveries, solutions, patterns, workflows, failures, and context rules.
/// Scoped to shared topics (or per-conversation when no topic is set).
/// JSON-backed with atomic writes.

import Foundation
import Logging
import ConfigurationSystem

private let ltmLogger = Logger(label: "com.sam.ltm")

// MARK: - LTM Scoring Constants (matching CLIO ContextBuilder.pm)

/// Minimum confidence for an LTM entry to be injected into system prompt.
let LTM_MIN_MEMORY_CONFIDENCE: Double = 0.5

/// Maximum number of relevant memories to project into context.
let LTM_MAX_RELEVANT_MEMORIES: Int = 5

/// Relevance threshold for an entry to be included in projection.
let LTM_RELEVANCE_THRESHOLD: Double = 5.0

// MARK: - LTM Data Types

/// A discovered fact about the project or codebase.
public struct LTMDiscovery: Codable, Sendable {
    public var fact: String
    public var confidence: Double
    public var verified: Bool
    public var timestamp: TimeInterval
    public var occurrences: Int
    /// Trust tier: "unverified" (default) or "trusted" (after corroboration).
    public var tier: String
    /// Number of independent corroborations from distinct agent:session pairs.
    public var corroborationCount: Int
    /// Source agent:session pairs that have corroborated this entry.
    public var corroborationSources: [String]
    /// When the entry was last updated (nil = same as timestamp).
    public var updated: TimeInterval?

    public init(fact: String, confidence: Double = 0.8, verified: Bool = false,
                tier: String = "unverified", corroborationCount: Int = 0,
                corroborationSources: [String] = []) {
        self.fact = fact
        self.confidence = confidence
        self.verified = verified
        self.timestamp = Date().timeIntervalSince1970
        self.occurrences = 1
        self.tier = tier
        self.corroborationCount = corroborationCount
        self.corroborationSources = corroborationSources
        self.updated = nil
    }

    enum CodingKeys: String, CodingKey {
        case fact, confidence, verified, timestamp, occurrences
        case tier, corroborationCount = "corroboration_count"
        case corroborationSources = "corroboration_sources"
        case updated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fact = try container.decode(String.self, forKey: .fact)
        confidence = try container.decode(Double.self, forKey: .confidence)
        verified = try container.decode(Bool.self, forKey: .verified)
        timestamp = try container.decode(TimeInterval.self, forKey: .timestamp)
        occurrences = try container.decodeIfPresent(Int.self, forKey: .occurrences) ?? 1
        tier = try container.decodeIfPresent(String.self, forKey: .tier) ?? "unverified"
        corroborationCount = try container.decodeIfPresent(Int.self, forKey: .corroborationCount) ?? 0
        corroborationSources = try container.decodeIfPresent([String].self, forKey: .corroborationSources) ?? []
        updated = try container.decodeIfPresent(TimeInterval.self, forKey: .updated)
    }
}

/// A problem-solution pair learned from debugging.
public struct LTMSolution: Codable, Sendable {
    public var error: String
    public var solution: String
    public var examples: [String]
    public var solvedCount: Int
    public var timestamp: TimeInterval
    /// Trust tier: "unverified" (default) or "trusted" (after corroboration).
    public var tier: String
    /// Number of independent corroborations from distinct agent:session pairs.
    public var corroborationCount: Int
    /// Source agent:session pairs that have corroborated this entry.
    public var corroborationSources: [String]
    /// When the entry was last updated (nil = same as timestamp).
    public var updated: TimeInterval?

    public init(error: String, solution: String, examples: [String] = [],
                tier: String = "unverified", corroborationCount: Int = 0,
                corroborationSources: [String] = []) {
        self.error = error
        self.solution = solution
        self.examples = examples
        self.solvedCount = 1
        self.timestamp = Date().timeIntervalSince1970
        self.tier = tier
        self.corroborationCount = corroborationCount
        self.corroborationSources = corroborationSources
        self.updated = nil
    }

    enum CodingKeys: String, CodingKey {
        case error, solution, examples
        case solvedCount = "solved_count"
        case timestamp
        case tier, corroborationCount = "corroboration_count"
        case corroborationSources = "corroboration_sources"
        case updated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        error = try container.decode(String.self, forKey: .error)
        solution = try container.decode(String.self, forKey: .solution)
        examples = try container.decodeIfPresent([String].self, forKey: .examples) ?? []
        solvedCount = try container.decodeIfPresent(Int.self, forKey: .solvedCount) ?? 1
        timestamp = try container.decode(TimeInterval.self, forKey: .timestamp)
        tier = try container.decodeIfPresent(String.self, forKey: .tier) ?? "unverified"
        corroborationCount = try container.decodeIfPresent(Int.self, forKey: .corroborationCount) ?? 0
        corroborationSources = try container.decodeIfPresent([String].self, forKey: .corroborationSources) ?? []
        updated = try container.decodeIfPresent(TimeInterval.self, forKey: .updated)
    }
}

/// A code or workflow pattern.
public struct LTMPattern: Codable, Sendable {
    public var pattern: String
    public var confidence: Double
    public var examples: [String]
    public var timestamp: TimeInterval
    public var occurrences: Int
    /// Trust tier: "unverified" (default) or "trusted" (after corroboration).
    public var tier: String
    /// Number of independent corroborations from distinct agent:session pairs.
    public var corroborationCount: Int
    /// Source agent:session pairs that have corroborated this entry.
    public var corroborationSources: [String]
    /// When the entry was last updated (nil = same as timestamp).
    public var updated: TimeInterval?

    public init(pattern: String, confidence: Double = 0.7, examples: [String] = [],
                tier: String = "unverified", corroborationCount: Int = 0,
                corroborationSources: [String] = []) {
        self.pattern = pattern
        self.confidence = confidence
        self.examples = examples
        self.timestamp = Date().timeIntervalSince1970
        self.occurrences = 1
        self.tier = tier
        self.corroborationCount = corroborationCount
        self.corroborationSources = corroborationSources
        self.updated = nil
    }

    enum CodingKeys: String, CodingKey {
        case pattern, confidence, examples, timestamp, occurrences
        case tier, corroborationCount = "corroboration_count"
        case corroborationSources = "corroboration_sources"
        case updated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pattern = try container.decode(String.self, forKey: .pattern)
        confidence = try container.decode(Double.self, forKey: .confidence)
        examples = try container.decodeIfPresent([String].self, forKey: .examples) ?? []
        timestamp = try container.decode(TimeInterval.self, forKey: .timestamp)
        occurrences = try container.decodeIfPresent(Int.self, forKey: .occurrences) ?? 1
        tier = try container.decodeIfPresent(String.self, forKey: .tier) ?? "unverified"
        corroborationCount = try container.decodeIfPresent(Int.self, forKey: .corroborationCount) ?? 0
        corroborationSources = try container.decodeIfPresent([String].self, forKey: .corroborationSources) ?? []
        updated = try container.decodeIfPresent(TimeInterval.self, forKey: .updated)
    }
}

/// A successful multi-step workflow.
public struct LTMWorkflow: Codable, Sendable {
    public var sequence: [String]
    public var successRate: Double
    public var count: Int
    public var timestamp: TimeInterval
    /// Trust tier: "unverified" (default) or "trusted" (after corroboration).
    public var tier: String
    /// Number of independent corroborations from distinct agent:session pairs.
    public var corroborationCount: Int
    /// Source agent:session pairs that have corroborated this entry.
    public var corroborationSources: [String]
    /// When the entry was last updated (nil = same as timestamp).
    public var updated: TimeInterval?

    public init(sequence: [String], successRate: Double = 1.0,
                tier: String = "unverified", corroborationCount: Int = 0,
                corroborationSources: [String] = []) {
        self.sequence = sequence
        self.successRate = successRate
        self.count = 1
        self.timestamp = Date().timeIntervalSince1970
        self.tier = tier
        self.corroborationCount = corroborationCount
        self.corroborationSources = corroborationSources
        self.updated = nil
    }

    enum CodingKeys: String, CodingKey {
        case sequence
        case successRate = "success_rate"
        case count, timestamp
        case tier, corroborationCount = "corroboration_count"
        case corroborationSources = "corroboration_sources"
        case updated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try container.decode([String].self, forKey: .sequence)
        successRate = try container.decode(Double.self, forKey: .successRate)
        count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 1
        timestamp = try container.decode(TimeInterval.self, forKey: .timestamp)
        tier = try container.decodeIfPresent(String.self, forKey: .tier) ?? "unverified"
        corroborationCount = try container.decodeIfPresent(Int.self, forKey: .corroborationCount) ?? 0
        corroborationSources = try container.decodeIfPresent([String].self, forKey: .corroborationSources) ?? []
        updated = try container.decodeIfPresent(TimeInterval.self, forKey: .updated)
    }
}

/// A known failure to avoid.
public struct LTMFailure: Codable, Sendable {
    public var what: String
    public var impact: String
    public var prevention: String
    public var occurrences: Int
    public var timestamp: TimeInterval
    /// Trust tier: "unverified" (default) or "trusted" (after corroboration).
    public var tier: String
    /// Number of independent corroborations from distinct agent:session pairs.
    public var corroborationCount: Int
    /// Source agent:session pairs that have corroborated this entry.
    public var corroborationSources: [String]
    /// When the entry was last updated (nil = same as timestamp).
    public var updated: TimeInterval?

    public init(what: String, impact: String, prevention: String,
                tier: String = "unverified", corroborationCount: Int = 0,
                corroborationSources: [String] = []) {
        self.what = what
        self.impact = impact
        self.prevention = prevention
        self.occurrences = 1
        self.timestamp = Date().timeIntervalSince1970
        self.tier = tier
        self.corroborationCount = corroborationCount
        self.corroborationSources = corroborationSources
        self.updated = nil
    }

    enum CodingKeys: String, CodingKey {
        case what, impact, prevention, occurrences, timestamp
        case tier, corroborationCount = "corroboration_count"
        case corroborationSources = "corroboration_sources"
        case updated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        what = try container.decode(String.self, forKey: .what)
        impact = try container.decode(String.self, forKey: .impact)
        prevention = try container.decode(String.self, forKey: .prevention)
        occurrences = try container.decodeIfPresent(Int.self, forKey: .occurrences) ?? 1
        timestamp = try container.decode(TimeInterval.self, forKey: .timestamp)
        tier = try container.decodeIfPresent(String.self, forKey: .tier) ?? "unverified"
        corroborationCount = try container.decodeIfPresent(Int.self, forKey: .corroborationCount) ?? 0
        corroborationSources = try container.decodeIfPresent([String].self, forKey: .corroborationSources) ?? []
        updated = try container.decodeIfPresent(TimeInterval.self, forKey: .updated)
    }
}

/// Container for all LTM patterns.
public struct LTMPatterns: Codable, Sendable {
    public var discoveries: [LTMDiscovery]
    public var problemSolutions: [LTMSolution]
    public var codePatterns: [LTMPattern]
    public var workflows: [LTMWorkflow]
    public var failures: [LTMFailure]
    public var contextRules: [String: [String]]

    public init() {
        discoveries = []
        problemSolutions = []
        codePatterns = []
        workflows = []
        failures = []
        contextRules = [:]
    }

    enum CodingKeys: String, CodingKey {
        case discoveries
        case problemSolutions = "problem_solutions"
        case codePatterns = "code_patterns"
        case workflows, failures
        case contextRules = "context_rules"
    }
}

/// Metadata about the LTM store.
public struct LTMMetadata: Codable, Sendable {
    public var createdAt: TimeInterval
    public var lastUpdated: TimeInterval
    public var version: String
    /// When consolidation was last run.
    public var lastConsolidated: TimeInterval?

    public init() {
        let now = Date().timeIntervalSince1970
        createdAt = now
        lastUpdated = now
        version = "1.0"
        lastConsolidated = nil
    }

    enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
        case lastUpdated = "last_updated"
        case version
        case lastConsolidated = "last_consolidated"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        createdAt = try container.decode(TimeInterval.self, forKey: .createdAt)
        lastUpdated = try container.decode(TimeInterval.self, forKey: .lastUpdated)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "1.0"
        lastConsolidated = try container.decodeIfPresent(TimeInterval.self, forKey: .lastConsolidated)
    }
}

/// Top-level JSON structure for ltm.json file.
struct LTMDocument: Codable {
    var patterns: LTMPatterns
    var metadata: LTMMetadata
}

// MARK: - LTM Entry Projection

/// A flat view of an LTM entry suitable for relevance scoring.
public struct LTMProjectionEntry: Sendable {
    public let content: String
    public let confidence: Double
    public let type: String
    public let rawScore: Double
    public let score: Double
    public let isMeta: Bool
    public let tier: String
    public let corroborationCount: Int

    public init(content: String, confidence: Double, type: String,
                rawScore: Double, score: Double, isMeta: Bool,
                tier: String, corroborationCount: Int) {
        self.content = content
        self.confidence = confidence
        self.type = type
        self.rawScore = rawScore
        self.score = score
        self.isMeta = isMeta
        self.tier = tier
        self.corroborationCount = corroborationCount
    }
}

// MARK: - Sanitization (ported from CLIO LongTerm.pm)

/// Framework-internal phrases that are pure narration with no recoverable content.
private let sanitizeDropPhrases: [String] = [
    // "After context trimming, use these patterns..."
    #"After context trimming[.:]?\s*use these patterns[^.]*\."#,
    // "To recover: 1. ... 2. ..."
    #"To recover:?\s*\d+\.\s*[^.]*\."#,
    // "_Showing X of Y memories..." block
    #"_Showing \d+ of \d+ memories.*?(?=\n\n|\Z)"#,
    // "_- N more solutions_" standalone lines
    #"_- \d+ more (solutions|discoveries|patterns|memories)_"#,
    // "Framework narration:" headers
    #"Framework narration[:.]?\s*[^.]*\."#,
    // Protocol invocation instructions
    #"before responding to any user request[,.\s]* ALWAYS[^.]+\."#,
    // "Failure mode this prevents:" meta-commentary
    #"Failure mode (this|it) prevents:\s*[^.]+(?:,\s*[^.]+)*\."#,
]

/// Framework-internal terms replaced with neutral descriptions.
/// Order: longer phrases first so "memory_operations(...)" matches before "memory_operations".
private let sanitizeReplacements: [(phrase: String, replacement: String)] = [
    ("memory_operations(...)", "long-term memory"),
    ("memory_operations", "long-term memory"),
    ("file_operations(...)", "file operations"),
    ("file_operations", "file operations"),
    ("terminal_operations(...)", "shell commands"),
    ("terminal_operations", "shell commands"),
    ("version_control(...)", "git operations"),
    ("version_control", "git operations"),
    ("todo_operations(...)", "todo operations"),
    ("todo_operations", "todo operations"),
    ("web_operations(...)", "web requests"),
    ("web_operations", "web requests"),
    ("apply_patch(...)", "patch operations"),
    ("apply_patch", "patch operations"),
    ("code_intelligence(...)", "code search"),
    ("code_intelligence", "code search"),
    ("interact(...)", "user input"),
    ("interact", "user input"),
    ("skill_operations(...)", "skill operations"),
    ("skill_operations", "skill operations"),
    ("remote_execution(...)", "remote execution"),
    ("remote_execution", "remote execution"),
    ("todo_list(...)", "todo list"),
    ("todo_list", "todo list"),
    ("recall_sessions", "session search"),
    ("prompt caching", "caching"),
    ("prompt cache", "cache"),
    ("LCP cache", "cache"),
    ("LCP", "cache prefix"),
    ("thread_summary", "thread summary"),
    ("userContext", "user context"),
    ("dynamicContext", "dynamic context"),
    ("activeTask", "active task"),
    ("activeTodos", "active todos"),
    ("unresolvedState", "unresolved state"),
    ("relevantMemory", "relevant memory"),
    ("contextFiles", "context files"),
    ("framework narration", "internal logging"),
    ("To recover", "To resolve"),
    ("recovery", "follow-up"),
    ("trim notice", "summary"),
    ("cache-collapse", "cache miss"),
    ("cache collapse", "cache miss"),
    ("validate_and_truncate", "context validation"),
    ("validate_tool_message_pairs", "tool message validation"),
    ("inject_context_files", "context file loading"),
    ("load_conversation_history", "session history loading"),
    ("trim_with_noise_dropping", "context trimming"),
    ("deinterleave", "restructure"),
    ("reinterleave", "restructure"),
    ("session_goals", "active goals"),
    ("in_flight_budget_exhausted", "budget exhausted"),
    ("messageHistory", "message history"),
    ("messages_to_prose_dynamic", "prose serializer"),
    ("ContextBuilder", "context builder"),
    ("MessageHistory.pm", "message history module"),
    ("PromptBuilder.pm", "prompt builder module"),
    ("WorkflowOrchestrator.pm", "workflow module"),
    ("ConversationManager.pm", "conversation manager module"),
]

/// Category words that signal a memory is about the framework itself.
private let categoryWords: Set<String> = [
    "prompt", "prompts", "context", "contexts", "cache", "caching",
    "ltm", "long-term memory", "framework", "projection", "model-facing",
    "narration", "trim", "trimming",
]

// MARK: - LongTermMemory Manager

/// Manages structured long-term memory storage.
/// Thread-safe via @MainActor isolation (consistent with SAM's actor model).
@MainActor
public class LongTermMemory: ObservableObject {
    internal var patterns: LTMPatterns
    internal var metadata: LTMMetadata
    private var filePath: String?
    private var isDirty: Bool = false

    // MARK: - Limits (matching CLIO defaults)

    public struct Limits {
        public var maxDiscoveries: Int = 50
        public var maxSolutions: Int = 50
        public var maxPatterns: Int = 30
        public var maxWorkflows: Int = 20
        public var maxFailures: Int = 20
        public var maxAgeDays: Int = 90
        public var minConfidence: Double = 0.3
    }

    public var limits = Limits()

    // MARK: - Lifecycle

    public init() {
        self.patterns = LTMPatterns()
        self.metadata = LTMMetadata()
    }

    /// Load LTM from a JSON file, or create empty if file doesn't exist.
    public static func load(from path: String) -> LongTermMemory {
        let ltm = LongTermMemory()
        ltm.filePath = path

        guard FileManager.default.fileExists(atPath: path) else {
            ltmLogger.debug("No LTM file at \(path), starting fresh")
            return ltm
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoder = JSONDecoder()
            let document = try decoder.decode(LTMDocument.self, from: data)
            ltm.patterns = document.patterns
            ltm.metadata = document.metadata
            let total = ltm.totalEntries
            ltmLogger.debug("Loaded LTM from \(path) (\(total) entries)")

            // Run consolidation on load (mirrors CLIO's maybe_consolidate
            // called during LongTerm::load). This applies confidence decay,
            // tier-aware age-out, and Jaccard dedup to keep LTM healthy.
            let consolResult = ltm.maybeConsolidate()
            if let consol = consolResult, consol.totalChanged > 0 {
                ltmLogger.info("Auto-consolidated LTM on load: removed=\(consol.removed), decayed=\(consol.decayed), deduped=\(consol.deduped), \(ltm.totalEntries) remaining")
                ltm.save(to: path)
            } else {
                // Fallback to prune for backward compatibility
                let pruneResult = ltm.prune()
                if pruneResult.removed > 0 {
                    ltmLogger.info("Auto-pruned LTM on load: removed \(pruneResult.removed) entries, \(pruneResult.remaining) remaining")
                    ltm.save(to: path)
                }
            }
        } catch {
            ltmLogger.warning("Failed to parse LTM file at \(path): \(error), starting fresh")
        }

        return ltm
    }

    /// Save LTM to its file path (atomic write).
    public func save() {
        guard let filePath = filePath else {
            ltmLogger.warning("No file path set for LTM, cannot save")
            return
        }

        guard isDirty else {
            ltmLogger.debug("LTM not dirty, skipping save")
            return
        }

        save(to: filePath)
    }

    /// Save LTM to a specific file path (atomic write).
    public func save(to path: String) {
        let document = LTMDocument(patterns: patterns, metadata: metadata)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(document)

            // Ensure directory exists
            let directory = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )

            // Atomic write: write to temp file, then rename
            let tempPath = path + ".tmp.\(ProcessInfo.processInfo.processIdentifier)"
            try data.write(to: URL(fileURLWithPath: tempPath), options: .atomic)

            // Move into place (atomic on APFS/HFS+)
            let fm = FileManager.default
            if fm.fileExists(atPath: path) {
                try fm.removeItem(atPath: path)
            }
            try fm.moveItem(atPath: tempPath, toPath: path)

            isDirty = false
            filePath = path
            ltmLogger.debug("Saved LTM to \(path)")
        } catch {
            ltmLogger.error("Failed to save LTM to \(path): \(error)")
        }
    }

    // MARK: - Sanitization

    /// Run the full sanitizer: drop-phrase removal + tool-name replacement + whitespace collapse.
    /// Used for non-code entries (discoveries, workflows, failures, context rules).
    /// Code patterns/solutions use sanitizeNarrationDropOnly to preserve tool names.
    private func sanitizeNarration(_ text: String) -> String {
        var result = text
        guard !result.isEmpty else { return result }

        // Drop pure-narration phrases (whole-sentence drops)
        for phrase in sanitizeDropPhrases {
            if let regex = try? NSRegularExpression(pattern: phrase, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: "")
            }
        }

        // Replace framework-internal terms (longer phrases first)
        let sortedReplacements = sanitizeReplacements.sorted { $0.phrase.count > $1.phrase.count }
        for (phrase, replacement) in sortedReplacements {
            let escaped = NSRegularExpression.escapedPattern(for: phrase)
            if let regex = try? NSRegularExpression(pattern: "\(escaped)", options: [.caseInsensitive]) {
                result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
            }
        }

        // Collapse multiple spaces left by drops
        result = result.replacingOccurrences(of: "[ \t]{2,}", with: " ", options: .regularExpression)
        // Trim leading/trailing whitespace per line
        result = result.replacingOccurrences(of: "^[ \t]+", with: "", options: [.regularExpression, .anchored])
        result = result.replacingOccurrences(of: "[ \t]+$", with: "", options: [.regularExpression, .anchored, .backwards])
        // Collapse 3+ blank lines to 2
        result = result.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        return result
    }

    /// Run only the drop-phrase cleanup from sanitizeNarration (no tool-name replacement).
    /// Used for code patterns/solutions that legitimately need tool names.
    private func sanitizeNarrationDropOnly(_ text: String) -> String {
        var result = text
        guard !result.isEmpty else { return result }

        for phrase in sanitizeDropPhrases {
            if let regex = try? NSRegularExpression(pattern: phrase, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: "")
            }
        }

        // Same whitespace collapse as sanitizeNarration
        result = result.replacingOccurrences(of: "[ \t]{2,}", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        return result
    }

    /// Replace relative date references with absolute dates.
    private func absolutizeDates(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        let now = Date().timeIntervalSince1970
        let today = isoDate(seconds: now)
        let yesterday = isoDate(seconds: now - 86400)
        let lastWeek = "week of \(isoDate(seconds: now - 7 * 86400))"
        let thisWeek = "week of \(isoDate(seconds: now))"
        let lastMonth = isoMonth(seconds: now - 30 * 86400)
        let thisMonth = isoMonth(seconds: now)

        var result = text
        result = replaceWord(in: result, word: "today", with: today)
        result = replaceWord(in: result, word: "yesterday", with: yesterday)
        result = replaceWord(in: result, word: "last week", with: lastWeek)
        result = replaceWord(in: result, word: "this week", with: thisWeek)
        result = replaceWord(in: result, word: "last month", with: lastMonth)
        result = replaceWord(in: result, word: "this month", with: thisMonth)

        return result
    }

    private func isoDate(seconds: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    private func isoMonth(seconds: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    private func replaceWord(in text: String, word: String, with replacement: String) -> String {
        guard !word.isEmpty else { return text }
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            return regex.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
        }
        return text
    }

    /// Internal: chain absolutize_dates + sanitize_narration for full sanitization.
    /// Used for non-code entries (discoveries, workflows, failures, rules).
    private func prepareForStorage(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = absolutizeDates(text)
        result = sanitizeNarration(result)
        return result
    }

    /// Internal: like prepareForStorage but skips tool-name replacement.
    /// Used for code patterns/solutions that need tool names preserved.
    private func prepareForStorageCode(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = absolutizeDates(text)
        result = sanitizeNarrationDropOnly(result)
        return result
    }

    // MARK: - Add Operations

    /// Add a discovered fact. Deduplicates by content similarity.
    /// Applies full sanitization (drop phrases + term replacement).
    public func addDiscovery(_ fact: String, confidence: Double = 0.8) {
        let sanitizedFact = prepareForStorage(fact)

        // Deduplicate: if a similar fact exists, increment occurrences
        if let idx = patterns.discoveries.firstIndex(where: { fuzzyMatch($0.fact, sanitizedFact) }) {
            patterns.discoveries[idx].occurrences += 1
            patterns.discoveries[idx].confidence = max(patterns.discoveries[idx].confidence, confidence)
            patterns.discoveries[idx].timestamp = Date().timeIntervalSince1970
            patterns.discoveries[idx].updated = Date().timeIntervalSince1970
        } else {
            patterns.discoveries.append(LTMDiscovery(fact: sanitizedFact, confidence: confidence))
        }

        metadata.lastUpdated = Date().timeIntervalSince1970
        isDirty = true
        ltmLogger.debug("Added discovery: \(sanitizedFact.prefix(80))")
    }

    /// Add a problem-solution pair.
    /// Uses _prepare_for_storage_code (drop phrases only, preserves tool names).
    public func addSolution(error: String, solution: String, examples: [String] = []) {
        let sanitizedError = prepareForStorageCode(error)
        let sanitizedSolution = prepareForStorageCode(solution)
        let sanitizedExamples = examples.map { prepareForStorageCode($0) }

        // Deduplicate: if a similar error exists, update solution and increment count
        if let idx = patterns.problemSolutions.firstIndex(where: { fuzzyMatch($0.error, sanitizedError) }) {
            patterns.problemSolutions[idx].solution = sanitizedSolution
            patterns.problemSolutions[idx].solvedCount += 1
            patterns.problemSolutions[idx].timestamp = Date().timeIntervalSince1970
            patterns.problemSolutions[idx].updated = Date().timeIntervalSince1970
            if !sanitizedExamples.isEmpty {
                let existing = Set(patterns.problemSolutions[idx].examples)
                patterns.problemSolutions[idx].examples += sanitizedExamples.filter { !existing.contains($0) }
            }
        } else {
            patterns.problemSolutions.append(LTMSolution(error: sanitizedError, solution: sanitizedSolution, examples: sanitizedExamples))
        }

        metadata.lastUpdated = Date().timeIntervalSince1970
        isDirty = true
        ltmLogger.debug("Added solution for: \(sanitizedError.prefix(80))")
    }

    /// Add a code/workflow pattern.
    /// Uses _prepare_for_storage_code (drop phrases only, preserves tool names).
    public func addPattern(_ pattern: String, confidence: Double = 0.7, examples: [String] = []) {
        let sanitizedPattern = prepareForStorageCode(pattern)
        let sanitizedExamples = examples.map { prepareForStorageCode($0) }

        if let idx = patterns.codePatterns.firstIndex(where: { fuzzyMatch($0.pattern, sanitizedPattern) }) {
            patterns.codePatterns[idx].occurrences += 1
            patterns.codePatterns[idx].confidence = max(patterns.codePatterns[idx].confidence, confidence)
            patterns.codePatterns[idx].timestamp = Date().timeIntervalSince1970
            patterns.codePatterns[idx].updated = Date().timeIntervalSince1970
            if !sanitizedExamples.isEmpty {
                let existing = Set(patterns.codePatterns[idx].examples)
                patterns.codePatterns[idx].examples += sanitizedExamples.filter { !existing.contains($0) }
            }
        } else {
            patterns.codePatterns.append(LTMPattern(pattern: sanitizedPattern, confidence: confidence, examples: sanitizedExamples))
        }

        metadata.lastUpdated = Date().timeIntervalSince1970
        isDirty = true
        ltmLogger.debug("Added pattern: \(sanitizedPattern.prefix(80))")
    }

    /// Add a successful workflow sequence.
    /// Applies full sanitization (workflows are prose, not code).
    public func addWorkflow(sequence: [String], successRate: Double = 1.0) {
        let sanitizedSequence = sequence.map { prepareForStorage($0) }

        if let idx = patterns.workflows.firstIndex(where: { $0.sequence == sanitizedSequence }) {
            patterns.workflows[idx].count += 1
            let existing = patterns.workflows[idx]
            patterns.workflows[idx].successRate =
                (existing.successRate * Double(existing.count - 1) + successRate) / Double(existing.count)
            patterns.workflows[idx].timestamp = Date().timeIntervalSince1970
            patterns.workflows[idx].updated = Date().timeIntervalSince1970
        } else {
            patterns.workflows.append(LTMWorkflow(sequence: sanitizedSequence, successRate: successRate))
        }

        metadata.lastUpdated = Date().timeIntervalSince1970
        isDirty = true
        ltmLogger.debug("Added workflow: \(sanitizedSequence.joined(separator: " -> "))")
    }

    /// Record a known failure to avoid.
    /// Applies full sanitization.
    public func addFailure(what: String, impact: String, prevention: String) {
        let sanitizedWhat = prepareForStorage(what)
        let sanitizedImpact = prepareForStorage(impact)
        let sanitizedPrevention = prepareForStorage(prevention)

        if let idx = patterns.failures.firstIndex(where: { fuzzyMatch($0.what, sanitizedWhat) }) {
            patterns.failures[idx].occurrences += 1
            patterns.failures[idx].impact = sanitizedImpact
            patterns.failures[idx].prevention = sanitizedPrevention
            patterns.failures[idx].timestamp = Date().timeIntervalSince1970
            patterns.failures[idx].updated = Date().timeIntervalSince1970
        } else {
            patterns.failures.append(LTMFailure(what: sanitizedWhat, impact: sanitizedImpact, prevention: sanitizedPrevention))
        }

        metadata.lastUpdated = Date().timeIntervalSince1970
        isDirty = true
        ltmLogger.debug("Added failure: \(sanitizedWhat.prefix(80))")
    }

    /// Add a context rule for a specific directory or module.
    /// Applies full sanitization to both context and rule.
    public func addContextRule(context: String, rule: String) {
        let sanitizedContext = prepareForStorage(context)
        let sanitizedRule = prepareForStorage(rule)

        if patterns.contextRules[sanitizedContext] == nil {
            patterns.contextRules[sanitizedContext] = []
        }

        guard !(patterns.contextRules[sanitizedContext]?.contains(sanitizedRule) ?? false) else { return }

        patterns.contextRules[sanitizedContext]?.append(sanitizedRule)
        metadata.lastUpdated = Date().timeIntervalSince1970
        isDirty = true
        ltmLogger.debug("Added context rule for \(sanitizedContext): \(sanitizedRule.prefix(80))")
    }

    // MARK: - Corroboration

    /// Result of an add_corroboration operation.
    public struct CorroborationResult: Sendable {
        public let found: Bool
        public let promoted: Bool
        public let tier: String
        public let corroborationCount: Int
        public let alreadyCorroborated: Bool
    }

    /// Add a corroboration to an existing LTM entry from an independent source.
    /// When corroboration_count reaches 2, entry is promoted to 'trusted' tier.
    public func addCorroboration(
        searchText: String,
        sourceAgent: String,
        sourceSession: String,
        typeFilter: String? = nil
    ) -> CorroborationResult {
        let sourceKey = "\(sourceAgent):\(sourceSession)"
        let searchLC = searchText.lowercased()
        let now = Date().timeIntervalSince1970

        // Normalize singular type names to category keys
        let categoryMap: [String: String] = [
            "discovery": "discoveries",
            "solution": "problem_solutions",
            "pattern": "code_patterns",
            "workflow": "workflows",
            "failure": "failures",
        ]

        let categories: [String]
        if let filter = typeFilter, let mapped = categoryMap[filter] {
            categories = [mapped]
        } else {
            categories = ["discoveries", "problem_solutions", "code_patterns", "workflows", "failures"]
        }

        var alreadyCorroborated = false

        for category in categories {
            switch category {
            case "discoveries":
                for i in patterns.discoveries.indices {
                    let text = entryText(patterns.discoveries[i], category: category)
                    guard text.lowercased().contains(searchLC) else { continue }
                    alreadyCorroborated = patterns.discoveries[i].corroborationSources.contains(sourceKey)
                    if alreadyCorroborated {
                        // Same source has already corroborated this entry —
                        // return without modifying state. CLIO's add_corroboration:
                        // skips append/increment when the source key is already present.
                        return CorroborationResult(found: true, promoted: false, tier: patterns.discoveries[i].tier,
                                                   corroborationCount: patterns.discoveries[i].corroborationCount,
                                                   alreadyCorroborated: true)
                    }
                    patterns.discoveries[i].corroborationSources.append(sourceKey)
                    patterns.discoveries[i].corroborationCount += 1
                    patterns.discoveries[i].updated = now
                    let promoted = patterns.discoveries[i].tier == "unverified" && patterns.discoveries[i].corroborationCount >= 2
                    if promoted { patterns.discoveries[i].tier = "trusted" }
                    metadata.lastUpdated = now
                    isDirty = true
                    ltmLogger.debug("Corroboration added to discoveries entry (count: \(patterns.discoveries[i].corroborationCount))")
                    return CorroborationResult(found: true, promoted: promoted, tier: patterns.discoveries[i].tier,
                                               corroborationCount: patterns.discoveries[i].corroborationCount,
                                               alreadyCorroborated: alreadyCorroborated)
                }
            case "problem_solutions":
                for i in patterns.problemSolutions.indices {
                    let text = entryText(patterns.problemSolutions[i], category: category)
                    guard text.lowercased().contains(searchLC) else { continue }
                    alreadyCorroborated = patterns.problemSolutions[i].corroborationSources.contains(sourceKey)
                    if alreadyCorroborated {
                        return CorroborationResult(found: true, promoted: false, tier: patterns.problemSolutions[i].tier,
                                                   corroborationCount: patterns.problemSolutions[i].corroborationCount,
                                                   alreadyCorroborated: true)
                    }
                    patterns.problemSolutions[i].corroborationSources.append(sourceKey)
                    patterns.problemSolutions[i].corroborationCount += 1
                    patterns.problemSolutions[i].updated = now
                    let promoted = patterns.problemSolutions[i].tier == "unverified" && patterns.problemSolutions[i].corroborationCount >= 2
                    if promoted { patterns.problemSolutions[i].tier = "trusted" }
                    metadata.lastUpdated = now
                    isDirty = true
                    ltmLogger.debug("Corroboration added to problem_solutions entry (count: \(patterns.problemSolutions[i].corroborationCount))")
                    return CorroborationResult(found: true, promoted: promoted, tier: patterns.problemSolutions[i].tier,
                                               corroborationCount: patterns.problemSolutions[i].corroborationCount,
                                               alreadyCorroborated: alreadyCorroborated)
                }
            case "code_patterns":
                for i in patterns.codePatterns.indices {
                    let text = entryText(patterns.codePatterns[i], category: category)
                    guard text.lowercased().contains(searchLC) else { continue }
                    alreadyCorroborated = patterns.codePatterns[i].corroborationSources.contains(sourceKey)
                    if alreadyCorroborated {
                        return CorroborationResult(found: true, promoted: false, tier: patterns.codePatterns[i].tier,
                                                   corroborationCount: patterns.codePatterns[i].corroborationCount,
                                                   alreadyCorroborated: true)
                    }
                    patterns.codePatterns[i].corroborationSources.append(sourceKey)
                    patterns.codePatterns[i].corroborationCount += 1
                    patterns.codePatterns[i].updated = now
                    let promoted = patterns.codePatterns[i].tier == "unverified" && patterns.codePatterns[i].corroborationCount >= 2
                    if promoted { patterns.codePatterns[i].tier = "trusted" }
                    metadata.lastUpdated = now
                    isDirty = true
                    ltmLogger.debug("Corroboration added to code_patterns entry (count: \(patterns.codePatterns[i].corroborationCount))")
                    return CorroborationResult(found: true, promoted: promoted, tier: patterns.codePatterns[i].tier,
                                               corroborationCount: patterns.codePatterns[i].corroborationCount,
                                               alreadyCorroborated: alreadyCorroborated)
                }
            case "workflows":
                for i in patterns.workflows.indices {
                    let text = entryText(patterns.workflows[i], category: category)
                    guard text.lowercased().contains(searchLC) else { continue }
                    alreadyCorroborated = patterns.workflows[i].corroborationSources.contains(sourceKey)
                    if alreadyCorroborated {
                        return CorroborationResult(found: true, promoted: false, tier: patterns.workflows[i].tier,
                                                   corroborationCount: patterns.workflows[i].corroborationCount,
                                                   alreadyCorroborated: true)
                    }
                    patterns.workflows[i].corroborationSources.append(sourceKey)
                    patterns.workflows[i].corroborationCount += 1
                    patterns.workflows[i].updated = now
                    let promoted = patterns.workflows[i].tier == "unverified" && patterns.workflows[i].corroborationCount >= 2
                    if promoted { patterns.workflows[i].tier = "trusted" }
                    metadata.lastUpdated = now
                    isDirty = true
                    ltmLogger.debug("Corroboration added to workflows entry (count: \(patterns.workflows[i].corroborationCount))")
                    return CorroborationResult(found: true, promoted: promoted, tier: patterns.workflows[i].tier,
                                               corroborationCount: patterns.workflows[i].corroborationCount,
                                               alreadyCorroborated: alreadyCorroborated)
                }
            case "failures":
                for i in patterns.failures.indices {
                    let text = entryText(patterns.failures[i], category: category)
                    guard text.lowercased().contains(searchLC) else { continue }
                    alreadyCorroborated = patterns.failures[i].corroborationSources.contains(sourceKey)
                    if alreadyCorroborated {
                        return CorroborationResult(found: true, promoted: false, tier: patterns.failures[i].tier,
                                                   corroborationCount: patterns.failures[i].corroborationCount,
                                                   alreadyCorroborated: true)
                    }
                    patterns.failures[i].corroborationSources.append(sourceKey)
                    patterns.failures[i].corroborationCount += 1
                    patterns.failures[i].updated = now
                    let promoted = patterns.failures[i].tier == "unverified" && patterns.failures[i].corroborationCount >= 2
                    if promoted { patterns.failures[i].tier = "trusted" }
                    metadata.lastUpdated = now
                    isDirty = true
                    ltmLogger.debug("Corroboration added to failures entry (count: \(patterns.failures[i].corroborationCount))")
                    return CorroborationResult(found: true, promoted: promoted, tier: patterns.failures[i].tier,
                                               corroborationCount: patterns.failures[i].corroborationCount,
                                               alreadyCorroborated: alreadyCorroborated)
                }
            default:
                break
            }
        }

        return CorroborationResult(found: false, promoted: false, tier: "unverified", corroborationCount: 0, alreadyCorroborated: false)
    }

    // MARK: - Entry Text Extraction (for corroboration search & Jaccard dedup)

    private func entryText(_ discovery: LTMDiscovery, category: String) -> String { discovery.fact }
    private func entryText(_ solution: LTMSolution, category: String) -> String { "\(solution.error) \(solution.solution)" }
    private func entryText(_ pattern: LTMPattern, category: String) -> String { pattern.pattern }
    private func entryText(_ workflow: LTMWorkflow, category: String) -> String { workflow.sequence.joined(separator: " ") }
    private func entryText(_ failure: LTMFailure, category: String) -> String { "\(failure.what) \(failure.impact) \(failure.prevention)" }

    // MARK: - Scoring

    /// Score an LTM entry for ranking. Higher score = more relevant.
    /// Ported from CLIO's LongTerm::score_entry.
    private func scoreEntry(_ entry: [String: Any], type: String, now: TimeInterval) -> Double {
        let confidence = entry["confidence"] as? Double ?? 0.5

        let timestamp = entry["updated"] as? TimeInterval ?? entry["timestamp"] as? TimeInterval ?? now
        let ageDays = (now - timestamp) / 86400
        let recency = exp(-0.693 * ageDays / 60)

        let typeWeights: [String: Double] = [
            "solution": 1.3,
            "pattern": 1.1,
            "discovery": 1.0,
            "workflow": 0.8,
            "failure": 0.9,
        ]
        let typeWeight = typeWeights[type] ?? 1.0

        var usage: Double = 1.0
        if type == "solution" {
            let solved = entry["solved_count"] as? Int ?? 1
            usage = 1.0 + log(1 + Double(solved)) * 0.3
        } else if type == "discovery" {
            usage = (entry["verified"] as? Bool ?? false) ? 1.2 : 0.9
        }

        let searchCount = entry["search_count"] as? Int ?? 0
        if searchCount > 0 {
            usage += log(1 + Double(searchCount)) * 0.2
        }

        let tier = entry["tier"] as? String ?? "unverified"
        let tierWeight = tier == "trusted" ? 1.0 : 0.3

        return confidence * recency * typeWeight * usage * tierWeight
    }

    /// Extract keywords from text for scoring.
    /// Ported from CLIO's _keywords.
    private func keywords(from text: String) -> Set<String> {
        guard !text.isEmpty else { return [] }
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0.count > 2 }
        return Set(words)
    }

    /// Compute keyword overlap between two keyword sets.
    private func keywordOverlap(_ a: Set<String>, _ b: Set<String>) -> Int {
        guard !a.isEmpty && !b.isEmpty else { return 0 }
        return a.intersection(b).count
    }

    /// Check if content contains framework-meta category words.
    private func isCategoryMatch(_ content: String) -> Bool {
        guard !content.isEmpty else { return false }
        let lc = content.lowercased()
        return categoryWords.contains { lc.contains($0) }
    }

    /// Count distinct framework-category words in content.
    private func metaCategoryCount(_ content: String) -> Int {
        guard !content.isEmpty else { return 0 }
        let lc = content.lowercased()
        var seen = Set<String>()
        var count = 0
        for word in categoryWords {
            let singleWord = word.hasPrefix(word.prefix(1).lowercased()) && !word.contains(" ")
            guard singleWord, !seen.contains(word) else { continue }
            seen.insert(word)
            if lc.contains(word) { count += 1 }
        }
        return count
    }

    /// Score LTM entries against the current request for projection.
    /// Ported from CLIO's ContextBuilder::score_ltm.
    /// Returns up to LTM_MAX_RELEVANT_MEMORIES entries with raw_score >= LTM_RELEVANCE_THRESHOLD,
    /// plus meta-matched entries with raw_score >= 3.
    public func scoreLtm(
        entries: [LTMProjectionEntry],
        currentUserInput: String,
        activeTask: String,
        unresolved: [String]
    ) -> [LTMProjectionEntry] {
        guard !entries.isEmpty else { return [] }

        let inputKeywords = keywords(from: currentUserInput)
        let taskKeywords = keywords(from: activeTask)
        let unresKeywords = keywords(from: unresolved.joined(separator: " "))
        let taskDiffers = (activeTask) != (currentUserInput)

        let inputIsMeta = isCategoryMatch(currentUserInput) || isCategoryMatch(activeTask)

        var scored: [LTMProjectionEntry] = []

        for entry in entries {
            // Lazy sanitize: pre-existing LTM entries may contain framework narration
            // written before the sanitizer existed. Clean them on read so the
            // prose renderer never sees the framework smell.
            let content: String
            if entry.type == "pattern" || entry.type == "solution" {
                content = sanitizeNarrationDropOnly(entry.content)
            } else {
                content = sanitizeNarration(entry.content)
            }
            guard !content.isEmpty else { continue }

            guard entry.confidence >= LTM_MIN_MEMORY_CONFIDENCE else { continue }

            let memKeywords = keywords(from: content)
            var rawScore: Double = 0
            rawScore += 3 * Double(keywordOverlap(inputKeywords, memKeywords))
            if taskDiffers {
                rawScore += 2 * Double(keywordOverlap(taskKeywords, memKeywords))
            }
            rawScore += 2 * Double(keywordOverlap(unresKeywords, memKeywords))
            rawScore += 1 * entry.confidence
            if inputIsMeta && metaCategoryCount(content) >= 2 {
                rawScore += 2
            }

            // Tier weight: ranking penalty only (does not gate injection)
            let tierWeight = entry.tier == "trusted" ? 1.0 : 0.3
            let score = rawScore * tierWeight
            let isMeta = inputIsMeta && metaCategoryCount(content) >= 2

            scored.append(LTMProjectionEntry(
                content: content,
                confidence: entry.confidence,
                type: entry.type,
                rawScore: rawScore,
                score: score,
                isMeta: isMeta,
                tier: entry.tier,
                corroborationCount: entry.corroborationCount
            ))
        }

        // Highest score first (penalized score ranks trusted above unverified)
        scored.sort { $0.score > $1.score }

        // Gate on raw_score (relevance), not penalized score
        let kept = scored.filter {
            $0.rawScore >= LTM_RELEVANCE_THRESHOLD || ($0.isMeta && $0.rawScore >= 3)
        }

        // Cap the list
        if kept.count > LTM_MAX_RELEVANT_MEMORIES {
            return Array(kept.prefix(LTM_MAX_RELEVANT_MEMORIES))
        }
        return kept
    }

    /// Build a flat projection of all LTM entries suitable for relevance scoring.
    /// Ported from CLIO's LongTerm::get_entries_for_projection.
    public func getEntriesForProjection() -> [LTMProjectionEntry] {
        var entries: [LTMProjectionEntry] = []

        for d in patterns.discoveries {
            entries.append(LTMProjectionEntry(
                content: d.fact, confidence: d.confidence, type: "discovery",
                rawScore: 0, score: 0, isMeta: false,
                tier: d.tier, corroborationCount: d.corroborationCount
            ))
        }
        for s in patterns.problemSolutions {
            let content = "\(s.error) \(s.solution)"
            entries.append(LTMProjectionEntry(
                content: content, confidence: 0.5, type: "solution",
                rawScore: 0, score: 0, isMeta: false,
                tier: s.tier, corroborationCount: s.corroborationCount
            ))
        }
        for p in patterns.codePatterns {
            entries.append(LTMProjectionEntry(
                content: p.pattern, confidence: p.confidence, type: "pattern",
                rawScore: 0, score: 0, isMeta: false,
                tier: p.tier, corroborationCount: p.corroborationCount
            ))
        }
        for w in patterns.workflows {
            let content = w.sequence.joined(separator: " ")
            entries.append(LTMProjectionEntry(
                content: content, confidence: 0.5, type: "workflow",
                rawScore: 0, score: 0, isMeta: false,
                tier: w.tier, corroborationCount: w.corroborationCount
            ))
        }
        for f in patterns.failures {
            let content = "\(f.what) \(f.impact) \(f.prevention)"
            entries.append(LTMProjectionEntry(
                content: content, confidence: 0.5, type: "failure",
                rawScore: 0, score: 0, isMeta: false,
                tier: f.tier, corroborationCount: f.corroborationCount
            ))
        }

        return entries
    }

    // MARK: - Consolidation

    /// Result of a consolidation pass.
    public struct ConsolidationStats: Sendable {
        public let removed: Int
        public let decayed: Int
        public let deduped: Int
        public var totalChanged: Int { removed + decayed + deduped }
    }

    /// Compute Jaccard similarity between two text strings (as sets of words).
    private func jaccardSimilarity(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty && $0.count > 2 })
        let wordsB = Set(b.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty && $0.count > 2 })
        guard !wordsA.isEmpty || !wordsB.isEmpty else { return 0 }
        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count
        return union > 0 ? Double(intersection) / Double(union) : 0
    }

    /// Run inline consolidation: confidence decay, age-out, hard caps, dedup.
    /// Ported from CLIO's LongTerm::consolidate.
    @discardableResult
    public func consolidate(
        maxAgeDays: Int = 90,
        confidenceDecayDays: Int = 60,
        maxDiscoveries: Int = 30,
        maxSolutions: Int = 30,
        maxPatterns: Int = 20,
        dedupThreshold: Double = 0.7
    ) -> ConsolidationStats {
        let now = Date().timeIntervalSince1970
        var removed = 0
        var decayed = 0
        var deduped = 0

        // Phase 1: Confidence decay for stale entries (unverified decay 2x faster)
        for i in patterns.discoveries.indices {
            let lastTouch = patterns.discoveries[i].updated ?? patterns.discoveries[i].timestamp
            let staleDays = (now - lastTouch) / 86400
            if staleDays > Double(confidenceDecayDays) {
                let periods = Int((staleDays - Double(confidenceDecayDays)) / 30)
                var decay = Double(periods) * 0.1
                if patterns.discoveries[i].tier == "unverified" { decay *= 2 }
                let oldConf = patterns.discoveries[i].confidence
                let newConf = max(oldConf - decay, 0.3)
                if newConf < oldConf {
                    patterns.discoveries[i].confidence = newConf
                    decayed += 1
                }
            }
        }
        for i in patterns.codePatterns.indices {
            let lastTouch = patterns.codePatterns[i].updated ?? patterns.codePatterns[i].timestamp
            let staleDays = (now - lastTouch) / 86400
            if staleDays > Double(confidenceDecayDays) {
                let periods = Int((staleDays - Double(confidenceDecayDays)) / 30)
                var decay = Double(periods) * 0.1
                if patterns.codePatterns[i].tier == "unverified" { decay *= 2 }
                let oldConf = patterns.codePatterns[i].confidence
                let newConf = max(oldConf - decay, 0.3)
                if newConf < oldConf {
                    patterns.codePatterns[i].confidence = newConf
                    decayed += 1
                }
            }
        }

        // Phase 2: Tier-aware age-out with counting
        let ageCutoff = now - Double(maxAgeDays * 86400)
        let unverifiedAgeCutoff = now - Double(30 * 86400)
        let discBefore = patterns.discoveries.count
        patterns.discoveries.removeAll { entry in
            let ts = entry.updated ?? entry.timestamp
            let conf = entry.confidence
            let tier = entry.tier
            if tier == "unverified" {
                return ts < unverifiedAgeCutoff && conf < 0.7
            } else {
                return ts < ageCutoff && conf < 0.5
            }
        }
        removed += discBefore - patterns.discoveries.count

        let patBefore = patterns.codePatterns.count
        patterns.codePatterns.removeAll { entry in
            let ts = entry.updated ?? entry.timestamp
            let conf = entry.confidence
            let tier = entry.tier
            if tier == "unverified" {
                return ts < unverifiedAgeCutoff && conf < 0.7
            } else {
                return ts < ageCutoff && conf < 0.5
            }
        }
        removed += patBefore - patterns.codePatterns.count

        // Phase 3: Jaccard deduplication for discoveries and code_patterns
        // Deduplicate discoveries
        if patterns.discoveries.count > 1 {
            var deduped_: [LTMDiscovery] = []
            var skipIndices = Set<Int>()
            for i in 0..<patterns.discoveries.count {
                if skipIndices.contains(i) { continue }
                var keep = true
                let textI = patterns.discoveries[i].fact
                for j in (i + 1)..<patterns.discoveries.count {
                    if skipIndices.contains(j) { continue }
                    let textJ = patterns.discoveries[j].fact
                    if jaccardSimilarity(textI, textJ) >= dedupThreshold {
                        let confI = patterns.discoveries[i].confidence
                        let confJ = patterns.discoveries[j].confidence
                        if confJ > confI {
                            skipIndices.insert(i)
                            deduped += 1
                            keep = false
                            break
                        } else {
                            skipIndices.insert(j)
                            deduped += 1
                        }
                    }
                }
                if keep { deduped_.append(patterns.discoveries[i]) }
            }
            patterns.discoveries = deduped_
        }
        // Deduplicate code_patterns
        if patterns.codePatterns.count > 1 {
            var deduped_: [LTMPattern] = []
            var skipIndices = Set<Int>()
            for i in 0..<patterns.codePatterns.count {
                if skipIndices.contains(i) { continue }
                var keep = true
                let textI = patterns.codePatterns[i].pattern
                for j in (i + 1)..<patterns.codePatterns.count {
                    if skipIndices.contains(j) { continue }
                    let textJ = patterns.codePatterns[j].pattern
                    if jaccardSimilarity(textI, textJ) >= dedupThreshold {
                        let confI = patterns.codePatterns[i].confidence
                        let confJ = patterns.codePatterns[j].confidence
                        if confJ > confI {
                            skipIndices.insert(i)
                            deduped += 1
                            keep = false
                            break
                        } else {
                            skipIndices.insert(j)
                            deduped += 1
                        }
                    }
                }
                if keep { deduped_.append(patterns.codePatterns[i]) }
            }
            patterns.codePatterns = deduped_
        }

        // Phase 4: Hard caps (keep highest-scored)
        if patterns.discoveries.count > maxDiscoveries {
            let now = Date().timeIntervalSince1970
            var withScores = patterns.discoveries.map { e -> (entry: LTMDiscovery, score: Double) in
                let s = self.scoreEntry([
                    "confidence": e.confidence,
                    "updated": e.updated ?? e.timestamp,
                    "timestamp": e.timestamp,
                    "tier": e.tier,
                    "solved_count": 0,
                    "verified": e.verified,
                    "search_count": 0,
                ], type: "discovery", now: now)
                return (e, s)
            }
            withScores.sort { $0.score > $1.score }
            removed += withScores.count - maxDiscoveries
            patterns.discoveries = withScores.prefix(maxDiscoveries).map { $0.entry }
        }
        if patterns.codePatterns.count > maxPatterns {
            let now = Date().timeIntervalSince1970
            var withScores = patterns.codePatterns.map { e -> (entry: LTMPattern, score: Double) in
                let s = self.scoreEntry([
                    "confidence": e.confidence,
                    "updated": e.updated ?? e.timestamp,
                    "timestamp": e.timestamp,
                    "tier": e.tier,
                    "solved_count": 0,
                    "search_count": 0,
                ], type: "pattern", now: now)
                return (e, s)
            }
            withScores.sort { $0.score > $1.score }
            removed += withScores.count - maxPatterns
            patterns.codePatterns = withScores.prefix(maxPatterns).map { $0.entry }
        }

        // Update metadata
        metadata.lastConsolidated = now
        metadata.lastUpdated = now
        isDirty = true

        let totalChanges = removed + decayed + deduped
        if totalChanges > 0 {
            ltmLogger.info("Consolidation: removed=\(removed), decayed=\(decayed), deduped=\(deduped)")
        }

        return ConsolidationStats(removed: removed, decayed: decayed, deduped: deduped)
    }

    /// Check gate conditions and run consolidation if needed.
    /// Called at session start during LTM load.
    public func maybeConsolidate(
        minHours: Double = 24,
        minEntries: Int = 20
    ) -> ConsolidationStats? {
        let now = Date().timeIntervalSince1970
        let lastConsol = metadata.lastConsolidated ?? 0
        let hoursSince = (now - lastConsol) / 3600

        if hoursSince < minHours {
            ltmLogger.debug("Consolidation skipped: only \(hoursSince)h since last (need \(minHours))")
            return nil
        }

        let total = patterns.discoveries.count + patterns.problemSolutions.count +
                     patterns.codePatterns.count + patterns.workflows.count + patterns.failures.count

        if total < minEntries {
            ltmLogger.debug("Consolidation skipped: only \(total) entries (need \(minEntries))")
            return nil
        }

        ltmLogger.debug("Running consolidation (\(total) entries, \(hoursSince)h since last)")
        return consolidate()
    }

    // MARK: - Query Operations

    /// Get discoveries, optionally limited.
    public func queryDiscoveries(limit: Int = 0) -> [LTMDiscovery] {
        let sorted = patterns.discoveries.sorted { $0.timestamp > $1.timestamp }
        return limit > 0 ? Array(sorted.prefix(limit)) : sorted
    }

    /// Get solutions, optionally limited.
    public func querySolutions(limit: Int = 0) -> [LTMSolution] {
        let sorted = patterns.problemSolutions.sorted { $0.solvedCount > $1.solvedCount }
        return limit > 0 ? Array(sorted.prefix(limit)) : sorted
    }

    /// Get code patterns, optionally limited.
    public func queryPatterns(limit: Int = 0) -> [LTMPattern] {
        let sorted = patterns.codePatterns.sorted { $0.confidence > $1.confidence }
        return limit > 0 ? Array(sorted.prefix(limit)) : sorted
    }

    /// Get workflows, optionally limited.
    public func queryWorkflows(limit: Int = 0) -> [LTMWorkflow] {
        let sorted = patterns.workflows.sorted { $0.count > $1.count }
        return limit > 0 ? Array(sorted.prefix(limit)) : sorted
    }

    /// Get failures, optionally limited.
    public func queryFailures(limit: Int = 0) -> [LTMFailure] {
        let sorted = patterns.failures.sorted { $0.timestamp > $1.timestamp }
        return limit > 0 ? Array(sorted.prefix(limit)) : sorted
    }

    /// Search solutions by error pattern.
    public func searchSolutions(errorPattern: String) -> [LTMSolution] {
        let lowered = errorPattern.lowercased()
        return patterns.problemSolutions
            .filter { $0.error.lowercased().contains(lowered) || lowered.contains($0.error.lowercased()) }
            .sorted { $0.solvedCount > $1.solvedCount }
    }

    /// Get patterns relevant to a specific file/module context.
    public func getPatternsForContext(_ context: String) -> (discoveries: [LTMDiscovery], rules: [(context: String, rules: [String])], patterns: [LTMPattern]) {
        var matchingRules: [(context: String, rules: [String])] = []
        for (ctx, rules) in patterns.contextRules {
            if context.contains(ctx) || ctx.contains(context) {
                matchingRules.append((context: ctx, rules: rules))
            }
        }
        return (patterns.discoveries, matchingRules, patterns.codePatterns)
    }

    // MARK: - Statistics

    /// Total number of entries across all categories.
    public var totalEntries: Int {
        patterns.discoveries.count +
        patterns.problemSolutions.count +
        patterns.codePatterns.count +
        patterns.workflows.count +
        patterns.failures.count +
        patterns.contextRules.values.reduce(0) { $0 + $1.count }
    }

    /// Get a summary of stored patterns.
    public func getSummary() -> [String: Any] {
        return [
            "discoveries": patterns.discoveries.count,
            "problem_solutions": patterns.problemSolutions.count,
            "code_patterns": patterns.codePatterns.count,
            "workflows": patterns.workflows.count,
            "failures": patterns.failures.count,
            "context_rules": patterns.contextRules.count,
            "last_updated": metadata.lastUpdated
        ]
    }

    // MARK: - Pruning

    /// Remove old, low-confidence, or excess entries.
    /// Tier-aware: unverified entries age out faster (30 days + 0.7 conf floor)
    /// and trusted entries get normal treatment (90 days + 0.5 floor).
    /// This mirrors CLIO's prune() to keep the two cleanup paths consistent.
    @discardableResult
    public func prune(
        maxAgeDays: Int? = nil,
        minConfidence: Double? = nil,
        maxDiscoveries: Int? = nil,
        maxSolutions: Int? = nil,
        maxPatterns: Int? = nil
    ) -> (removed: Int, remaining: Int) {
        let ageDays = maxAgeDays ?? limits.maxAgeDays
        let confidence = minConfidence ?? limits.minConfidence
        let maxDisc = maxDiscoveries ?? limits.maxDiscoveries
        let maxSol = maxSolutions ?? limits.maxSolutions
        let maxPat = maxPatterns ?? limits.maxPatterns

        let before = totalEntries
        let now = Date().timeIntervalSince1970
        let ageCutoff = now - Double(ageDays * 86400)
        let unverifiedAgeCutoff = now - Double(30 * 86400)
        let unverifiedMinConfidence: Double = 0.7

        // Prune by age and confidence (tier-aware)
        patterns.discoveries.removeAll { entry in
            let ts = entry.updated ?? entry.timestamp
            let conf = entry.confidence
            let tier = entry.tier
            if tier == "trusted" {
                return ts < ageCutoff || conf < confidence
            } else {
                return ts < unverifiedAgeCutoff || conf < max(confidence, unverifiedMinConfidence)
            }
        }
        patterns.problemSolutions.removeAll { entry in
            let ts = entry.updated ?? entry.timestamp
            let tier = entry.tier
            if tier == "trusted" {
                return ts < ageCutoff
            } else {
                return ts < unverifiedAgeCutoff
            }
        }
        patterns.codePatterns.removeAll { entry in
            let ts = entry.updated ?? entry.timestamp
            let conf = entry.confidence
            let tier = entry.tier
            if tier == "trusted" {
                return ts < ageCutoff || conf < confidence
            } else {
                return ts < unverifiedAgeCutoff || conf < max(confidence, unverifiedMinConfidence)
            }
        }
        patterns.workflows.removeAll { entry in
            let ts = entry.updated ?? entry.timestamp
            let tier = entry.tier
            if tier == "trusted" {
                return ts < ageCutoff
            } else {
                return ts < unverifiedAgeCutoff
            }
        }
        patterns.failures.removeAll { entry in
            let ts = entry.updated ?? entry.timestamp
            let tier = entry.tier
            if tier == "trusted" {
                return ts < ageCutoff
            } else {
                return ts < unverifiedAgeCutoff
            }
        }

        // Enforce max counts (keep highest quality)
        if patterns.discoveries.count > maxDisc {
            patterns.discoveries.sort { $0.confidence > $1.confidence }
            patterns.discoveries = Array(patterns.discoveries.prefix(maxDisc))
        }
        if patterns.problemSolutions.count > maxSol {
            patterns.problemSolutions.sort { $0.solvedCount > $1.solvedCount }
            patterns.problemSolutions = Array(patterns.problemSolutions.prefix(maxSol))
        }
        if patterns.codePatterns.count > maxPat {
            patterns.codePatterns.sort { $0.confidence > $1.confidence }
            patterns.codePatterns = Array(patterns.codePatterns.prefix(maxPat))
        }

        let after = totalEntries
        let removed = before - after

        if removed > 0 {
            metadata.lastUpdated = Date().timeIntervalSince1970
            isDirty = true
            ltmLogger.info("Pruned LTM: removed \(removed) entries, \(after) remaining")
        }

        return (removed, after)
    }

    // MARK: - System Prompt Formatting

    /// Format LTM patterns for injection into system prompt.
    /// Applies lazy sanitization on read (matching CLIO's score_ltm).
    /// Patterns/solutions use drop-only (preserves tool names);
    /// other types use full sanitization.
    public func formatForSystemPrompt() -> String {
        // When there's no query context, project ALL eligible entries (not just
        // query-relevant ones). This is the "general summary" path used in
        // production (AgentOrchestrator) where LTM is injected as a static
        // system prompt block, not a query-specific projection.
        let entries = getEntriesForProjection()

        // Apply lazy sanitization + confidence gating (matching scoreLtm logic
        // but WITHOUT the relevance threshold gate — all eligible entries pass).
        var scored: [LTMProjectionEntry] = []
        for entry in entries {
            let content: String
            if entry.type == "pattern" || entry.type == "solution" {
                content = sanitizeNarrationDropOnly(entry.content)
            } else {
                content = sanitizeNarration(entry.content)
            }
            guard !content.isEmpty else { continue }
            guard entry.confidence >= LTM_MIN_MEMORY_CONFIDENCE else { continue }

            // Score: just confidence * tier weight (no keyword overlap, no threshold gate)
            let tierWeight = entry.tier == "trusted" ? 1.0 : 0.3
            let score = entry.confidence * tierWeight
            scored.append(LTMProjectionEntry(
                content: content,
                confidence: entry.confidence,
                type: entry.type,
                rawScore: entry.confidence,
                score: score,
                isMeta: false,
                tier: entry.tier,
                corroborationCount: entry.corroborationCount
            ))
        }

        // Sort by score (trusted entries rank above unverified with same confidence)
        scored.sort { $0.score > $1.score }

        // Cap the list
        if scored.count > LTM_MAX_RELEVANT_MEMORIES {
            scored = Array(scored.prefix(LTM_MAX_RELEVANT_MEMORIES))
        }

        guard !scored.isEmpty else { return "" }

        let discoveries = scored.filter { $0.type == "discovery" }
        let solutions = scored.filter { $0.type == "solution" }
        let codePatterns = scored.filter { $0.type == "pattern" }
        let workflows = scored.filter { $0.type == "workflow" }
        let failures = scored.filter { $0.type == "failure" }

        let total = scored.count
        guard total > 0 else { return "" }

        var section = "## Long-Term Memory Patterns\n\n"
        section += "The following patterns have been learned from previous conversations:\n\n"

        if !discoveries.isEmpty {
            section += "### Key Discoveries\n\n"
            for item in discoveries {
                let tierLabel = item.tier == "trusted" ? "Verified" : "Unverified"
                let conf = String(format: "%.0f%%", item.confidence * 100)
                section += "- **\(item.content)** (Confidence: \(conf), \(tierLabel))\n"
            }
            section += "\n"
        }

        if !solutions.isEmpty {
            section += "### Problem Solutions\n\n"
            for item in solutions {
                section += "**Problem:** \(item.content)\n"
                section += "_Applied successfully_\n\n"
            }
        }

        if !codePatterns.isEmpty {
            section += "### Code Patterns\n\n"
            for item in codePatterns {
                let conf = String(format: "%.0f%%", item.confidence * 100)
                section += "- **\(item.content)** (Confidence: \(conf))\n"
            }
            section += "\n"
        }

        if !workflows.isEmpty {
            section += "### Successful Workflows\n\n"
            for item in workflows {
                section += "- \(item.content)\n"
            }
            section += "\n"
        }

        if !failures.isEmpty {
            section += "### Known Failures (Avoid These)\n\n"
            for item in failures {
                section += "- \(item.content)\n\n"
            }
        }

        section += "_These patterns are conversation-specific and should inform your approach to similar tasks._\n"
        section += "\n_After context trimming, use these patterns plus `long-term memory recall` to recover context instead of repeating work._\n"

        return section
    }

    // MARK: - Private Helpers

    /// Simple fuzzy matching: checks if strings share significant content.
    private func fuzzyMatch(_ a: String, _ b: String) -> Bool {
        let aLower = a.lowercased()
        let bLower = b.lowercased()
        // Exact match
        if aLower == bLower { return true }
        // Contains match (one contains the other)
        if aLower.contains(bLower) || bLower.contains(aLower) { return true }
        // Word overlap: if 60%+ of words overlap, consider it a match
        let aWords = Set(aLower.split(separator: " ").map(String.init))
        let bWords = Set(bLower.split(separator: " ").map(String.init))
        guard !aWords.isEmpty && !bWords.isEmpty else { return false }
        let overlap = aWords.intersection(bWords).count
        let minCount = min(aWords.count, bWords.count)
        return minCount > 0 && Double(overlap) / Double(minCount) >= 0.6
    }
}

// MARK: - LTM Path Resolution

extension LongTermMemory {
    /// Get the LTM file path for a conversation's scope.
    /// - If conversation has a shared topic, LTM is stored in the topic's directory.
    /// - Otherwise, LTM is stored per-conversation in Application Support.
    public static func resolveFilePath(
        conversationId: UUID,
        sharedTopicId: UUID? = nil,
        sharedTopicName: String? = nil,
        useSharedData: Bool = false
    ) -> String {
        let fm = FileManager.default

        if useSharedData, let _ = sharedTopicId, let topicName = sharedTopicName {
            // Shared topic LTM: stored in topic's working directory
            let safeName = topicName.replacingOccurrences(of: "/", with: "-")
            let topicPath = WorkingDirectoryConfiguration.shared.buildPath(subdirectory: safeName)
            let topicDir = URL(fileURLWithPath: topicPath, isDirectory: true)
            let ltmDir = topicDir.appendingPathComponent(".sam")
            try? fm.createDirectory(at: ltmDir, withIntermediateDirectories: true)
            return ltmDir.appendingPathComponent("ltm.json").path
        }

        // Per-conversation LTM
        do {
            let appSupport = try fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let conversationDir = appSupport
                .appendingPathComponent("SAM")
                .appendingPathComponent("conversations")
                .appendingPathComponent(conversationId.uuidString)
            try fm.createDirectory(at: conversationDir, withIntermediateDirectories: true)
            return conversationDir.appendingPathComponent("ltm.json").path
        } catch {
            ltmLogger.error("Failed to resolve LTM path: \(error)")
            return "/tmp/sam-ltm-\(conversationId.uuidString).json"
        }
    }
}
