// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

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

// MARK: - LTM Data Types

/// A discovered fact about the project or codebase.
public struct LTMDiscovery: Codable, Sendable {
    public var fact: String
    public var confidence: Double
    public var verified: Bool
    public var timestamp: TimeInterval
    public var occurrences: Int

    public init(fact: String, confidence: Double = 0.8, verified: Bool = false) {
        self.fact = fact
        self.confidence = confidence
        self.verified = verified
        self.timestamp = Date().timeIntervalSince1970
        self.occurrences = 1
    }
}

/// A problem-solution pair learned from debugging.
public struct LTMSolution: Codable, Sendable {
    public var error: String
    public var solution: String
    public var examples: [String]
    public var solvedCount: Int
    public var timestamp: TimeInterval

    public init(error: String, solution: String, examples: [String] = []) {
        self.error = error
        self.solution = solution
        self.examples = examples
        self.solvedCount = 1
        self.timestamp = Date().timeIntervalSince1970
    }

    enum CodingKeys: String, CodingKey {
        case error, solution, examples
        case solvedCount = "solved_count"
        case timestamp
    }
}

/// A code or workflow pattern.
public struct LTMPattern: Codable, Sendable {
    public var pattern: String
    public var confidence: Double
    public var examples: [String]
    public var timestamp: TimeInterval
    public var occurrences: Int

    public init(pattern: String, confidence: Double = 0.7, examples: [String] = []) {
        self.pattern = pattern
        self.confidence = confidence
        self.examples = examples
        self.timestamp = Date().timeIntervalSince1970
        self.occurrences = 1
    }
}

/// A successful multi-step workflow.
public struct LTMWorkflow: Codable, Sendable {
    public var sequence: [String]
    public var successRate: Double
    public var count: Int
    public var timestamp: TimeInterval

    public init(sequence: [String], successRate: Double = 1.0) {
        self.sequence = sequence
        self.successRate = successRate
        self.count = 1
        self.timestamp = Date().timeIntervalSince1970
    }

    enum CodingKeys: String, CodingKey {
        case sequence
        case successRate = "success_rate"
        case count, timestamp
    }
}

/// A known failure to avoid.
public struct LTMFailure: Codable, Sendable {
    public var what: String
    public var impact: String
    public var prevention: String
    public var occurrences: Int
    public var timestamp: TimeInterval

    public init(what: String, impact: String, prevention: String) {
        self.what = what
        self.impact = impact
        self.prevention = prevention
        self.occurrences = 1
        self.timestamp = Date().timeIntervalSince1970
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

    public init() {
        let now = Date().timeIntervalSince1970
        createdAt = now
        lastUpdated = now
        version = "1.0"
    }

    enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
        case lastUpdated = "last_updated"
        case version
    }
}

/// Top-level JSON structure for ltm.json file.
struct LTMDocument: Codable {
    var patterns: LTMPatterns
    var metadata: LTMMetadata
}

// MARK: - LongTermMemory Manager

/// Manages structured long-term memory storage.
/// Thread-safe via @MainActor isolation (consistent with SAM's actor model).
@MainActor
public class LongTermMemory: ObservableObject {
    private var patterns: LTMPatterns
    private var metadata: LTMMetadata
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

            // Auto-prune on load to keep LTM healthy
            let pruneResult = ltm.prune()
            if pruneResult.removed > 0 {
                ltmLogger.info("Auto-pruned LTM on load: removed \(pruneResult.removed) entries, \(pruneResult.remaining) remaining")
                ltm.save(to: path)
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

    // MARK: - Add Operations

    /// Add a discovered fact. Deduplicates by content similarity.
    public func addDiscovery(_ fact: String, confidence: Double = 0.8) {
        // Deduplicate: if a similar fact exists, increment occurrences
        if let idx = patterns.discoveries.firstIndex(where: { fuzzyMatch($0.fact, fact) }) {
            patterns.discoveries[idx].occurrences += 1
            patterns.discoveries[idx].confidence = max(patterns.discoveries[idx].confidence, confidence)
            patterns.discoveries[idx].timestamp = Date().timeIntervalSince1970
        } else {
            patterns.discoveries.append(LTMDiscovery(fact: fact, confidence: confidence))
        }

        metadata.lastUpdated = Date().timeIntervalSince1970
        isDirty = true
        ltmLogger.debug("Added discovery: \(fact.prefix(80))")
    }

    /// Add a problem-solution pair.
    public func addSolution(error: String, solution: String, examples: [String] = []) {
        // Deduplicate: if a similar error exists, update solution and increment count
        if let idx = patterns.problemSolutions.firstIndex(where: { fuzzyMatch($0.error, error) }) {
            patterns.problemSolutions[idx].solution = solution
            patterns.problemSolutions[idx].solvedCount += 1
            patterns.problemSolutions[idx].timestamp = Date().timeIntervalSince1970
            if !examples.isEmpty {
                let existing = Set(patterns.problemSolutions[idx].examples)
                patterns.problemSolutions[idx].examples += examples.filter { !existing.contains($0) }
            }
        } else {
            patterns.problemSolutions.append(LTMSolution(error: error, solution: solution, examples: examples))
        }

        metadata.lastUpdated = Date().timeIntervalSince1970
        isDirty = true
        ltmLogger.debug("Added solution for: \(error.prefix(80))")
    }

    /// Add a code/workflow pattern.
    public func addPattern(_ pattern: String, confidence: Double = 0.7, examples: [String] = []) {
        if let idx = patterns.codePatterns.firstIndex(where: { fuzzyMatch($0.pattern, pattern) }) {
            patterns.codePatterns[idx].occurrences += 1
            patterns.codePatterns[idx].confidence = max(patterns.codePatterns[idx].confidence, confidence)
            patterns.codePatterns[idx].timestamp = Date().timeIntervalSince1970
            if !examples.isEmpty {
                let existing = Set(patterns.codePatterns[idx].examples)
                patterns.codePatterns[idx].examples += examples.filter { !existing.contains($0) }
            }
        } else {
            patterns.codePatterns.append(LTMPattern(pattern: pattern, confidence: confidence, examples: examples))
        }

        metadata.lastUpdated = Date().timeIntervalSince1970
        isDirty = true
        ltmLogger.debug("Added pattern: \(pattern.prefix(80))")
    }

    /// Add a successful workflow sequence.
    public func addWorkflow(sequence: [String], successRate: Double = 1.0) {
        if let idx = patterns.workflows.firstIndex(where: { $0.sequence == sequence }) {
            patterns.workflows[idx].count += 1
            let existing = patterns.workflows[idx]
            patterns.workflows[idx].successRate =
                (existing.successRate * Double(existing.count - 1) + successRate) / Double(existing.count)
            patterns.workflows[idx].timestamp = Date().timeIntervalSince1970
        } else {
            patterns.workflows.append(LTMWorkflow(sequence: sequence, successRate: successRate))
        }

        metadata.lastUpdated = Date().timeIntervalSince1970
        isDirty = true
        ltmLogger.debug("Added workflow: \(sequence.joined(separator: " -> "))")
    }

    /// Record a known failure to avoid.
    public func addFailure(what: String, impact: String, prevention: String) {
        if let idx = patterns.failures.firstIndex(where: { fuzzyMatch($0.what, what) }) {
            patterns.failures[idx].occurrences += 1
            patterns.failures[idx].impact = impact
            patterns.failures[idx].prevention = prevention
            patterns.failures[idx].timestamp = Date().timeIntervalSince1970
        } else {
            patterns.failures.append(LTMFailure(what: what, impact: impact, prevention: prevention))
        }

        metadata.lastUpdated = Date().timeIntervalSince1970
        isDirty = true
        ltmLogger.debug("Added failure: \(what.prefix(80))")
    }

    /// Add a context rule for a specific directory or module.
    public func addContextRule(context: String, rule: String) {
        if patterns.contextRules[context] == nil {
            patterns.contextRules[context] = []
        }

        guard !(patterns.contextRules[context]?.contains(rule) ?? false) else { return }

        patterns.contextRules[context]?.append(rule)
        metadata.lastUpdated = Date().timeIntervalSince1970
        isDirty = true
        ltmLogger.debug("Added context rule for \(context): \(rule.prefix(80))")
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
    /// Returns (removed count, remaining count).
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
        let cutoff = Date().timeIntervalSince1970 - Double(ageDays * 86400)

        // Prune by age and confidence
        patterns.discoveries.removeAll { $0.timestamp < cutoff || $0.confidence < confidence }
        patterns.problemSolutions.removeAll { $0.timestamp < cutoff }
        patterns.codePatterns.removeAll { $0.timestamp < cutoff || $0.confidence < confidence }
        patterns.workflows.removeAll { $0.timestamp < cutoff }
        patterns.failures.removeAll { $0.timestamp < cutoff }

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
    /// Matches CLIO's PromptBuilder.generate_ltm_section format.
    public func formatForSystemPrompt() -> String {
        let discoveries = queryDiscoveries(limit: 3)
        let solutions = querySolutions(limit: 3)
        let codePatterns = queryPatterns(limit: 3)
        let workflows = queryWorkflows(limit: 2)
        let failures = queryFailures(limit: 2)

        let total = discoveries.count + solutions.count + codePatterns.count + workflows.count + failures.count
        guard total > 0 else { return "" }

        var section = "## Long-Term Memory Patterns\n\n"
        section += "The following patterns have been learned from previous conversations:\n\n"

        if !discoveries.isEmpty {
            section += "### Key Discoveries\n\n"
            for item in discoveries {
                let verified = item.verified ? "Verified" : "Unverified"
                let conf = String(format: "%.0f%%", item.confidence * 100)
                section += "- **\(item.fact)** (Confidence: \(conf), \(verified))\n"
            }
            section += "\n"
        }

        if !solutions.isEmpty {
            section += "### Problem Solutions\n\n"
            for item in solutions {
                section += "**Problem:** \(item.error)\n"
                section += "**Solution:** \(item.solution)\n"
                let times = item.solvedCount == 1 ? "time" : "times"
                section += "_Applied successfully \(item.solvedCount) \(times)_\n\n"
            }
        }

        if !codePatterns.isEmpty {
            section += "### Code Patterns\n\n"
            for item in codePatterns {
                let conf = String(format: "%.0f%%", item.confidence * 100)
                section += "- **\(item.pattern)** (Confidence: \(conf))\n"
                if !item.examples.isEmpty {
                    section += "  Examples: \(item.examples.joined(separator: ", "))\n"
                }
            }
            section += "\n"
        }

        if !workflows.isEmpty {
            section += "### Successful Workflows\n\n"
            for item in workflows {
                if !item.sequence.isEmpty {
                    section += "- \(item.sequence.joined(separator: " -> "))\n"
                    let rate = String(format: "%.0f%%", item.successRate * 100)
                    let attempts = item.count == 1 ? "attempt" : "attempts"
                    section += "  _Success rate: \(rate) (\(item.count) \(attempts))_\n"
                }
            }
            section += "\n"
        }

        if !failures.isEmpty {
            section += "### Known Failures (Avoid These)\n\n"
            for item in failures {
                section += "**What broke:** \(item.what)\n"
                section += "**Impact:** \(item.impact)\n"
                section += "**Prevention:** \(item.prevention)\n\n"
            }
        }

        section += "_These patterns are conversation-specific and should inform your approach to similar tasks._\n"
        section += "\n_After context trimming, use these patterns plus `memory_operations(operation: \"recall_history\")` to recover context instead of repeating work._\n"

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
