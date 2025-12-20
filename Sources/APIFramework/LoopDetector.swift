// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// LoopDetector.swift SAM Advanced loop detection using pattern analysis and multi-heuristic scoring Analyzes workflowRounds to detect semantic loops and intervention strategies.

import Foundation
import Logging

/// Advanced loop detection system using pattern analysis Replaces simple counter-based detection with intelligent heuristics.
public class LoopDetector {
    private let logger = Logger(label: "com.sam.loop_detector")

    /// Configuration for loop detection thresholds and weights.
    public struct Configuration: Codable, Sendable {
        /// Heuristic weights (must sum to 1.0).
        let repetitionWeight: Double
        let similarityWeight: Double
        let errorWeight: Double
        let progressWeight: Double
        let timeWeight: Double

        /// Intervention thresholds.
        let warningThreshold: Double
        let suggestionThreshold: Double
        let blockingThreshold: Double
        let terminationThreshold: Double

        /// Analysis parameters.
        let analysisWindowSize: Int
        let minCallsForPattern: Int

        /// Default configuration (tuned for production use).
        public static let `default` = Configuration(
            repetitionWeight: 0.20,
            similarityWeight: 0.25,
            errorWeight: 0.30,
            progressWeight: 0.15,
            timeWeight: 0.10,
            warningThreshold: 0.3,
            suggestionThreshold: 0.5,
            blockingThreshold: 0.7,
            terminationThreshold: 0.9,
            analysisWindowSize: 10,
            minCallsForPattern: 3
        )

        /// Conservative configuration (more permissive, fewer interventions).
        public static let conservative = Configuration(
            repetitionWeight: 0.15,
            similarityWeight: 0.20,
            errorWeight: 0.35,
            progressWeight: 0.20,
            timeWeight: 0.10,
            warningThreshold: 0.4,
            suggestionThreshold: 0.6,
            blockingThreshold: 0.8,
            terminationThreshold: 0.95,
            analysisWindowSize: 15,
            minCallsForPattern: 4
        )

        /// Aggressive configuration (strict, early interventions).
        public static let aggressive = Configuration(
            repetitionWeight: 0.25,
            similarityWeight: 0.30,
            errorWeight: 0.25,
            progressWeight: 0.10,
            timeWeight: 0.10,
            warningThreshold: 0.25,
            suggestionThreshold: 0.4,
            blockingThreshold: 0.6,
            terminationThreshold: 0.8,
            analysisWindowSize: 8,
            minCallsForPattern: 2
        )
    }

    private let config: Configuration

    public init(configuration: Configuration = .default) {
        self.config = configuration
        logger.debug("SUCCESS: LoopDetector initialized", metadata: [
            "analysisWindow": .stringConvertible(configuration.analysisWindowSize),
            "warningThreshold": .stringConvertible(configuration.warningThreshold)
        ])
    }

    // MARK: - Pattern Detection

    /// Analyze workflow rounds to detect loop patterns.
    public func analyzePatterns(rounds: [WorkflowRound]) -> [DetectedPattern] {
        guard rounds.count >= config.minCallsForPattern else {
            return []
        }

        /// Get recent rounds for analysis.
        let recentRounds = Array(rounds.suffix(config.analysisWindowSize))

        /// Group tool calls by tool name.
        var toolCallsByName: [String: [(round: WorkflowRound, call: ToolCallInfo)]] = [:]
        for round in recentRounds {
            for toolCall in round.toolCalls {
                toolCallsByName[toolCall.name, default: []].append((round, toolCall))
            }
        }

        /// Analyze each tool for patterns.
        var detectedPatterns: [DetectedPattern] = []
        for (toolName, calls) in toolCallsByName {
            if calls.count >= config.minCallsForPattern {
                if let pattern = analyzeToolPattern(toolName: toolName, calls: calls, allRounds: recentRounds) {
                    detectedPatterns.append(pattern)
                }
            }
        }

        return detectedPatterns.sorted { $0.score.composite > $1.score.composite }
    }

    /// Analyze a specific tool for loop patterns.
    private func analyzeToolPattern(
        toolName: String,
        calls: [(round: WorkflowRound, call: ToolCallInfo)],
        allRounds: [WorkflowRound]
    ) -> DetectedPattern? {

        /// Calculate individual heuristic scores.
        let repetitionScore = calculateRepetitionScore(calls: calls, totalRounds: allRounds.count)
        let similarityScore = calculateSimilarityScore(calls: calls)
        let errorScore = calculateErrorScore(calls: calls)
        let progressScore = calculateProgressScore(rounds: allRounds, toolName: toolName)
        let timeScore = calculateTimeScore(calls: calls)

        let score = LoopScore(
            repetitionScore: repetitionScore,
            similarityScore: similarityScore,
            errorScore: errorScore,
            progressScore: progressScore,
            timeScore: timeScore,
            weights: (
                config.repetitionWeight,
                config.similarityWeight,
                config.errorWeight,
                config.progressWeight,
                config.timeWeight
            )
        )

        /// Only return pattern if composite score exceeds warning threshold.
        guard score.composite >= config.warningThreshold else {
            return nil
        }

        /// Extract pattern metadata.
        let arguments = calls.map { $0.call.arguments }
        let errors = calls.compactMap { $0.call.error }
        let firstTimestamp = calls.first?.round.timestamp ?? Date()
        let lastTimestamp = calls.last?.round.timestamp ?? Date()

        return DetectedPattern(
            toolName: toolName,
            callCount: calls.count,
            score: score,
            sampleArguments: arguments.prefix(3).map { String($0) },
            commonErrors: Array(Set(errors)).prefix(3).map { String($0) },
            timeSinceFirstOccurrence: lastTimestamp.timeIntervalSince(firstTimestamp),
            interventionLevel: determineInterventionLevel(score: score.composite)
        )
    }

    // MARK: - Heuristic Calculations

    /// Calculate repetition score (how often tool is called).
    private func calculateRepetitionScore(calls: [(round: WorkflowRound, call: ToolCallInfo)], totalRounds: Int) -> Double {
        /// Score based on proportion of rounds containing this tool.
        let callCount = calls.count
        let proportion = Double(callCount) / Double(totalRounds)

        /// 50%+ of rounds = 1.0 score.
        return min(1.0, proportion * 2.0)
    }

    /// Calculate similarity score (how similar are the arguments).
    private func calculateSimilarityScore(calls: [(round: WorkflowRound, call: ToolCallInfo)]) -> Double {
        guard calls.count >= 2 else { return 0.0 }

        var totalSimilarity = 0.0
        let arguments = calls.map { $0.call.arguments }

        /// Compare consecutive calls.
        for i in 0..<(arguments.count - 1) {
            let similarity = calculateArgumentSimilarity(arguments[i], arguments[i + 1])
            totalSimilarity += similarity
        }

        return totalSimilarity / Double(arguments.count - 1)
    }

    /// Calculate error score (repeated errors).
    private func calculateErrorScore(calls: [(round: WorkflowRound, call: ToolCallInfo)]) -> Double {
        let errors = calls.compactMap { $0.call.error }
        guard !errors.isEmpty else { return 0.0 }

        /// Count error occurrences.
        let errorCounts = Dictionary(grouping: errors, by: { $0 })
            .mapValues { $0.count }

        let maxRepeatError = errorCounts.values.max() ?? 0

        /// 3+ identical errors = 1.0 score.
        return min(1.0, Double(maxRepeatError) / 3.0)
    }

    /// Calculate progress score (declining success rate).
    private func calculateProgressScore(rounds: [WorkflowRound], toolName: String) -> Double {
        guard rounds.count >= 6 else { return 0.0 }

        /// Split into first and second half.
        let midpoint = rounds.count / 2
        let firstHalf = Array(rounds.prefix(midpoint))
        let secondHalf = Array(rounds.suffix(rounds.count - midpoint))

        let firstSuccessRate = calculateSuccessRate(firstHalf, toolName: toolName)
        let secondSuccessRate = calculateSuccessRate(secondHalf, toolName: toolName)

        /// If success rate declining, that's lack of progress.
        if secondSuccessRate < firstSuccessRate {
            let decline = firstSuccessRate - secondSuccessRate
            return min(1.0, decline * 2.0)
        }

        return 0.0
    }

    /// Calculate time score (stuck for too long).
    private func calculateTimeScore(calls: [(round: WorkflowRound, call: ToolCallInfo)]) -> Double {
        guard let firstTimestamp = calls.first?.round.timestamp,
              let lastTimestamp = calls.last?.round.timestamp else {
            return 0.0
        }

        let duration = lastTimestamp.timeIntervalSince(firstTimestamp)

        /// 5+ minutes of same pattern = 1.0 score.
        return min(1.0, duration / 300.0)
    }

    // MARK: - Helper Methods

    /// Calculate success rate for rounds containing specific tool.
    private func calculateSuccessRate(_ rounds: [WorkflowRound], toolName: String) -> Double {
        let relevantRounds = rounds.filter { round in
            round.toolCalls.contains { $0.name == toolName }
        }

        guard !relevantRounds.isEmpty else { return 0.0 }

        let successfulRounds = relevantRounds.filter { round in
            round.toolCalls.filter { $0.name == toolName }.contains { $0.success }
        }

        return Double(successfulRounds.count) / Double(relevantRounds.count)
    }

    /// Calculate argument similarity using Levenshtein distance.
    func calculateArgumentSimilarity(_ args1: String, _ args2: String) -> Double {
        /// Try JSON comparison first (more accurate for structured arguments).
        if let similarity = compareJSONArguments(args1, args2) {
            return similarity
        }

        /// Fall back to string similarity.
        let distance = levenshteinDistance(args1, args2)
        let maxLength = max(args1.count, args2.count)
        guard maxLength > 0 else { return 1.0 }

        return 1.0 - (Double(distance) / Double(maxLength))
    }

    /// Compare JSON arguments (returns nil if not valid JSON).
    private func compareJSONArguments(_ args1: String, _ args2: String) -> Double? {
        guard let data1 = args1.data(using: .utf8),
              let data2 = args2.data(using: .utf8),
              let json1 = try? JSONSerialization.jsonObject(with: data1),
              let json2 = try? JSONSerialization.jsonObject(with: data2) else {
            return nil
        }

        return compareJSONObjects(json1, json2)
    }

    /// Compare JSON objects recursively.
    private func compareJSONObjects(_ obj1: Any, _ obj2: Any) -> Double {
        /// Same type and value.
        if let dict1 = obj1 as? [String: Any], let dict2 = obj2 as? [String: Any] {
            return compareDictionaries(dict1, dict2)
        }

        if let arr1 = obj1 as? [Any], let arr2 = obj2 as? [Any] {
            return compareArrays(arr1, arr2)
        }

        /// Primitive values.
        let str1 = String(describing: obj1)
        let str2 = String(describing: obj2)
        return str1 == str2 ? 1.0 : 0.0
    }

    /// Compare dictionaries.
    private func compareDictionaries(_ dict1: [String: Any], _ dict2: [String: Any]) -> Double {
        let allKeys = Set(dict1.keys).union(Set(dict2.keys))
        guard !allKeys.isEmpty else { return 1.0 }

        var totalSimilarity = 0.0
        for key in allKeys {
            if let val1 = dict1[key], let val2 = dict2[key] {
                totalSimilarity += compareJSONObjects(val1, val2)
            }
            /// Missing keys count as 0.0 similarity.
        }

        return totalSimilarity / Double(allKeys.count)
    }

    /// Compare arrays.
    private func compareArrays(_ arr1: [Any], _ arr2: [Any]) -> Double {
        let maxLength = max(arr1.count, arr2.count)
        guard maxLength > 0 else { return 1.0 }

        let minLength = min(arr1.count, arr2.count)
        var totalSimilarity = 0.0

        for i in 0..<minLength {
            totalSimilarity += compareJSONObjects(arr1[i], arr2[i])
        }

        /// Account for length difference.
        return totalSimilarity / Double(maxLength)
    }

    /// Levenshtein distance algorithm.
    func levenshteinDistance(_ str1: String, _ str2: String) -> Int {
        let s1 = Array(str1)
        let s2 = Array(str2)

        var matrix = Array(repeating: Array(repeating: 0, count: s2.count + 1), count: s1.count + 1)

        /// Initialize first row and column.
        for i in 0...s1.count {
            matrix[i][0] = i
        }
        for j in 0...s2.count {
            matrix[0][j] = j
        }

        /// Fill matrix.
        for i in 1...s1.count {
            for j in 1...s2.count {
                let cost = s1[i - 1] == s2[j - 1] ? 0 : 1
                matrix[i][j] = min(
                    matrix[i - 1][j] + 1,
                    matrix[i][j - 1] + 1,
                    matrix[i - 1][j - 1] + cost
                )
            }
        }

        return matrix[s1.count][s2.count]
    }

    /// Determine intervention level from composite score.
    private func determineInterventionLevel(score: Double) -> InterventionLevel {
        if score >= config.terminationThreshold {
            return .termination
        } else if score >= config.blockingThreshold {
            return .blocking
        } else if score >= config.suggestionThreshold {
            return .suggestion
        } else if score >= config.warningThreshold {
            return .warning
        } else {
            return .none
        }
    }

    // MARK: - Intervention Recommendations

    /// Get recommended intervention action for detected pattern Returns tuple of (InterventionAction, metrics data for reporting).
    public func recommendIntervention(
        pattern: DetectedPattern
    ) -> (action: InterventionAction, metricsData: [String: Any]) {
        logger.debug("LOOP_PATTERN_ANALYZED", metadata: [
            "tool": .string(pattern.toolName),
            "callCount": .stringConvertible(pattern.callCount),
            "compositeScore": .stringConvertible(pattern.score.composite),
            "level": .string("\(pattern.interventionLevel)")
        ])

        /// Build metrics data dictionary.
        let actionDescription: String
        switch pattern.interventionLevel {
        case .none: actionDescription = "none"
        case .warning: actionDescription = "warning"
        case .suggestion: actionDescription = "suggestion_thinking_required"
        case .blocking: actionDescription = "tool_blocked"
        case .termination: actionDescription = "workflow_terminated"
        }

        let metricsData: [String: Any] = [
            "toolName": pattern.toolName,
            "callCount": pattern.callCount,
            "compositeScore": pattern.score.composite,
            "interventionLevel": "\(pattern.interventionLevel)",
            "actionTaken": actionDescription
        ]

        let action: InterventionAction

        switch pattern.interventionLevel {
        case .none:
            action = .continue

        case .warning:
            action = .warning(message: generateWarningMessage(pattern))

        case .suggestion:
            action = .requireThinking(prompt: generateThinkingPrompt(pattern))

        case .blocking:
            action = .blockTool(
                toolName: pattern.toolName,
                reason: generateBlockingReason(pattern),
                suggestedAlternatives: getSuggestedAlternatives(pattern.toolName)
            )

        case .termination:
            action = .terminate(reason: generateTerminationReason(pattern))
        }

        return (action, metricsData)
    }

    // MARK: - Message Generation

    private func generateWarningMessage(_ pattern: DetectedPattern) -> String {
        return "WARNING: Pattern detected: You've called \(pattern.toolName) \(pattern.callCount) times in recent rounds. Consider trying a different approach if current method isn't working."
    }

    private func generateThinkingPrompt(_ pattern: DetectedPattern) -> String {
        let errorInfo = pattern.commonErrors.isEmpty ? "" : "\n- Encountering errors: \(pattern.commonErrors.joined(separator: ", "))"

        return """
        You appear to be in a loop:
        - Called \(pattern.toolName) \(pattern.callCount) times in \(config.analysisWindowSize) recent rounds
        - Argument similarity: \(String(format: "%.0f%%", pattern.score.similarityScore * 100))
        - Repetition score: \(String(format: "%.2f", pattern.score.repetitionScore))\(errorInfo)

        REQUIRED: Use the think tool to:
        1. Acknowledge the pattern you're stuck in
        2. Explain why current approach isn't working
        3. Propose a different approach or tool
        4. If truly stuck, use user_collaboration to ask for guidance
        """
    }

    private func generateBlockingReason(_ pattern: DetectedPattern) -> String {
        return "Loop detected: Called \(pattern.toolName) \(pattern.callCount) times without sufficient progress (score: \(String(format: "%.2f", pattern.score.composite))). Try a different tool or approach."
    }

    private func generateTerminationReason(_ pattern: DetectedPattern) -> String {
        return """
        Workflow terminated due to critical loop pattern:
        - Tool: \(pattern.toolName)
        - Called: \(pattern.callCount) times in \(config.analysisWindowSize) rounds
        - Loop score: \(String(format: "%.2f", pattern.score.composite))
        - Time elapsed: \(String(format: "%.1f", pattern.timeSinceFirstOccurrence / 60.0)) minutes

        This usually indicates the current approach cannot solve the problem.
        Please review the workflow and try a different strategy.
        """
    }

    /// Get suggested alternative tools.
    private func getSuggestedAlternatives(_ toolName: String) -> [String] {
        switch toolName {
        case "web_operations":
            return ["document_operations", "memory_operations (search)", "user_collaboration"]

        case "file_operations":
            return ["grep_search", "semantic_search", "terminal_operations"]

        case "terminal_operations":
            return ["file_operations", "build_and_version_control"]

        case "think":
            return ["user_collaboration", "memory_operations (search)", "continuation_status (WORK_COMPLETE)"]

        case "memory_operations":
            return ["document_operations", "web_operations", "user_collaboration"]

        default:
            return ["user_collaboration", "think", "different tool approach"]
        }
    }
}

// MARK: - Supporting Types

/// Detected loop pattern with scoring.
public struct DetectedPattern {
    public let toolName: String
    public let callCount: Int
    public let score: LoopScore
    public let sampleArguments: [String]
    public let commonErrors: [String]
    public let timeSinceFirstOccurrence: TimeInterval
    public let interventionLevel: InterventionLevel
}

/// Multi-heuristic loop score.
public struct LoopScore {
    public let repetitionScore: Double
    public let similarityScore: Double
    public let errorScore: Double
    public let progressScore: Double
    public let timeScore: Double

    /// Weighted composite score.
    public var composite: Double {
        let (repWeight, simWeight, errWeight, progWeight, timeWeight) = weights
        return (
            repetitionScore * repWeight +
            similarityScore * simWeight +
            errorScore * errWeight +
            progressScore * progWeight +
            timeScore * timeWeight
        )
    }

    private let weights: (Double, Double, Double, Double, Double)

    init(
        repetitionScore: Double,
        similarityScore: Double,
        errorScore: Double,
        progressScore: Double,
        timeScore: Double,
        weights: (Double, Double, Double, Double, Double)
    ) {
        self.repetitionScore = repetitionScore
        self.similarityScore = similarityScore
        self.errorScore = errorScore
        self.progressScore = progressScore
        self.timeScore = timeScore
        self.weights = weights
    }
}

/// Intervention level based on loop severity.
public enum InterventionLevel: Comparable {
    case none
    case warning
    case suggestion
    case blocking
    case termination
}

/// Recommended intervention action.
public enum InterventionAction {
    case `continue`
    case warning(message: String)
    case requireThinking(prompt: String)
    case blockTool(toolName: String, reason: String, suggestedAlternatives: [String])
    case terminate(reason: String)
}
